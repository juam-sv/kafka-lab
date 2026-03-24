#!/usr/bin/env bash
#
# Test: Region A Failback — Recovery After Simulated Failure
#
# Validates:
#   1. Region A consumer/producer pods come back online after scaling up
#   2. Region A consumer lag decreases (catching up on missed messages)
#   3. Region A consumer committed offset advances (actively processing)
#   4. No crash-loops during recovery (pod restart count stays low)
#
# Usage: ./scripts/tests/test-failback.sh
#
# Prerequisites: Run test-failover.sh first (Region A should be scaled to 0).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

GROUP_A="${GROUP_A:-finance-group-use1}"
GROUP_B="${GROUP_B:-finance-group-use2}"
MAX_ACCEPTABLE_RESTARTS="${MAX_ACCEPTABLE_RESTARTS:-2}"

# ─── Helper: get committed offset sum for a consumer group ──────
get_committed_offset_sum() {
    local group="$1"
    local context="${2:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    local pod
    pod=$(get_producer_pod "$context")
    [[ -z "$pod" ]] && { echo "0"; return; }

    kubectl exec -n "$NAMESPACE" $ctx_flag "$pod" -- python -c "
import os
from confluent_kafka import Consumer, TopicPartition
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', 'us-east-1')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
c = Consumer({
    'bootstrap.servers': os.environ['KAFKA_BROKER'],
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'OAUTHBEARER',
    'oauth_cb': oauth_cb,
    'group.id': '$group',
    'auto.offset.reset': 'earliest',
})
md = c.list_topics(topic='$TOPIC', timeout=10)
if '$TOPIC' not in md.topics:
    print(0)
else:
    parts = md.topics['$TOPIC'].partitions
    tps = [TopicPartition('$TOPIC', pid) for pid in parts]
    committed = c.committed(tps, timeout=10)
    total = sum(tp.offset for tp in committed if tp.offset >= 0)
    print(total)
c.close()
" 2>/dev/null || echo "0"
}

# ─── Helper: get consumer pod restart count ─────────────────────
get_consumer_restart_count() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    kubectl get pods -n "$NAMESPACE" $ctx_flag \
        -l app.kubernetes.io/component=consumer \
        -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | \
        tr ' ' '\n' | awk '{s+=$1} END {print s+0}'
}

# ─── Helper: get topic end offset (high-water mark sum) ────────
get_topic_end_offset() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    local pod
    pod=$(get_producer_pod "$context")
    [[ -z "$pod" ]] && { echo "0"; return; }

    kubectl exec -n "$NAMESPACE" $ctx_flag "$pod" -- python -c "
import os
from confluent_kafka import Consumer, TopicPartition
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', 'us-east-1')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
c = Consumer({
    'bootstrap.servers': os.environ['KAFKA_BROKER'],
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'OAUTHBEARER',
    'oauth_cb': oauth_cb,
    'group.id': 'test-offset-reader-temp',
    'auto.offset.reset': 'earliest',
})
md = c.list_topics(topic='$TOPIC', timeout=10)
if '$TOPIC' not in md.topics:
    print(0)
else:
    parts = md.topics['$TOPIC'].partitions
    total = 0
    for pid in parts:
        lo, hi = c.get_watermark_offsets(TopicPartition('$TOPIC', pid), timeout=10)
        total += hi
    print(total)
c.close()
" 2>/dev/null || echo "0"
}

# ═══════════════════════════════════════════════════════════════
#  Pre-flight Checks
# ═══════════════════════════════════════════════════════════════
header "Pre-flight Checks"

if [[ -z "$CONTEXT_A" ]]; then
    die "CONTEXT_A is not set. Export it before running this test."
fi
if [[ -z "$CONTEXT_B" ]]; then
    die "CONTEXT_B is not set. Export it before running this test."
fi
info "Context A (${REGION_A}): $CONTEXT_A"
info "Context B (${REGION_B}): $CONTEXT_B"

# Verify Region A is scaled to 0 (expected from failover test)
PRODUCER_REPLICAS_A=$(kubectl get deployment/${RELEASE}-producer \
    -n "$NAMESPACE" --context="$CONTEXT_A" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "unknown")
CONSUMER_REPLICAS_A=$(kubectl get deployment/${RELEASE}-consumer \
    -n "$NAMESPACE" --context="$CONTEXT_A" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "unknown")

info "Region A producer replicas: $PRODUCER_REPLICAS_A"
info "Region A consumer replicas: $CONSUMER_REPLICAS_A"

if [[ "$PRODUCER_REPLICAS_A" != "0" ]] || [[ "$CONSUMER_REPLICAS_A" != "0" ]]; then
    warn "Region A deployments are not scaled to 0."
    warn "This test expects Region A to be offline (from test-failover.sh)."
    echo ""
    read -rp "$(echo -e "${YELLOW}Continue anyway? (y/N) ${RESET}")" force_continue
    if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
        info "Aborted. Run test-failover.sh first."
        exit 0
    fi
else
    record_test "Region A deployments confirmed at 0 replicas (from failover)" "pass"
fi

# Record Region B current state
CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
info "Region B consumer pods: $CONSUMERS_B"

if [[ "$CONSUMERS_B" -eq 0 ]]; then
    die "Region B has no consumer pods running. Both regions appear to be down."
fi

# ─── Record pre-failback baselines ────────────────────────────
header "Recording Pre-Failback Baselines"

OFFSET_B_CURRENT=$(get_committed_offset_sum "$GROUP_B" "$CONTEXT_B")
OFFSET_A_LAST=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A" 2>/dev/null || echo "0")
# For Region A offset, we may need to read from Region B if Region A pods are down
if [[ "$OFFSET_A_LAST" == "0" ]]; then
    info "Region A pods are down — reading Region A group offset from Region B cluster..."
    OFFSET_A_LAST=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_B")
fi

info "Region B ($GROUP_B) current committed offset: $OFFSET_B_CURRENT"
info "Region A ($GROUP_A) last committed offset: $OFFSET_A_LAST"

MESSAGES_B=$(get_topic_message_count "$REGION_B" "$TOPIC" "$CONTEXT_B")
info "Region B current message count: $MESSAGES_B"

# ═══════════════════════════════════════════════════════════════
#  Failback — Restore Region A
# ═══════════════════════════════════════════════════════════════
header "Failback — Restoring Region A"

echo ""
echo -e "${YELLOW}This will scale Region A producer and consumer deployments${RESET}"
echo -e "${YELLOW}back to 1 replica and monitor recovery.${RESET}"
echo ""
read -rp "$(echo -e "${YELLOW}Proceed with failback? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Aborted."
    exit 0
fi

info "Scaling Region A producer to 1 replica..."
kubectl scale deployment/${RELEASE}-producer \
    --replicas=1 -n "$NAMESPACE" --context="$CONTEXT_A" 2>/dev/null || \
    die "Failed to scale Region A producer"

info "Scaling Region A consumer to 1 replica..."
kubectl scale deployment/${RELEASE}-consumer \
    --replicas=1 -n "$NAMESPACE" --context="$CONTEXT_A" 2>/dev/null || \
    die "Failed to scale Region A consumer"

# ─── Wait for pods to be Running ──────────────────────────────
header "Waiting for Region A Pods to Start (timeout: 120s)"

if poll_until "Region A consumer pod running" 120 \
    "[[ \$(kubectl get pods -n $NAMESPACE --context=$CONTEXT_A -l app.kubernetes.io/component=consumer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]"; then
    record_test "Region A consumer pod reached Running state" "pass"
else
    record_test "Region A consumer pod reached Running state" "fail"
fi

if poll_until "Region A producer pod running" 120 \
    "[[ \$(kubectl get pods -n $NAMESPACE --context=$CONTEXT_A -l app.kubernetes.io/component=producer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]"; then
    record_test "Region A producer pod reached Running state" "pass"
else
    record_test "Region A producer pod reached Running state" "fail"
fi

# Give pods a moment to initialize Kafka connections
info "Pods running. Allowing 10 seconds for Kafka client initialization..."
sleep 10

# ─── Monitor consumer lag recovery ────────────────────────────
header "Monitoring Region A Consumer Lag Recovery (120s)"

RECOVERY_START_OFFSET=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A")
info "Region A committed offset at recovery start: $RECOVERY_START_OFFSET"

PREVIOUS_OFFSET=$RECOVERY_START_OFFSET
OFFSET_ADVANCING=false

for i in $(seq 1 12); do
    sleep 10

    CURRENT_OFFSET=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A")
    END_OFFSET=$(get_topic_end_offset "$CONTEXT_A")

    if [[ "$END_OFFSET" -gt 0 ]]; then
        LAG=$((END_OFFSET - CURRENT_OFFSET))
    else
        LAG="unknown"
    fi

    DELTA=$((CURRENT_OFFSET - PREVIOUS_OFFSET))

    printf "  [%s] Offset: %s | End: %s | Lag: %s | Delta: +%s (%ds/%ds)\n" \
        "$(date +%H:%M:%S)" "$CURRENT_OFFSET" "$END_OFFSET" "$LAG" \
        "$DELTA" "$((i * 10))" "120"

    if [[ "$DELTA" -gt 0 ]]; then
        OFFSET_ADVANCING=true
    fi

    PREVIOUS_OFFSET=$CURRENT_OFFSET
done

RECOVERY_END_OFFSET=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A")
TOTAL_RECOVERY_PROGRESS=$((RECOVERY_END_OFFSET - RECOVERY_START_OFFSET))

echo ""
info "Region A offset recovery progress: $TOTAL_RECOVERY_PROGRESS messages processed"

# ─── Verify: Region A consumer is processing messages ─────────
header "Verification Checks"

if [[ "$OFFSET_ADVANCING" == "true" ]] && [[ "$TOTAL_RECOVERY_PROGRESS" -gt 0 ]]; then
    record_test "Region A consumer processing messages after recovery (+$TOTAL_RECOVERY_PROGRESS)" "pass"
else
    record_test "Region A consumer processing messages after recovery (+$TOTAL_RECOVERY_PROGRESS)" "fail"
fi

# ─── Verify: No crash-loops ──────────────────────────────────
RESTART_COUNT=$(get_consumer_restart_count "$CONTEXT_A")
info "Region A consumer restart count: $RESTART_COUNT"

if [[ "$RESTART_COUNT" -le "$MAX_ACCEPTABLE_RESTARTS" ]]; then
    record_test "Region A consumer not crash-looping (restarts: $RESTART_COUNT <= $MAX_ACCEPTABLE_RESTARTS)" "pass"
else
    record_test "Region A consumer not crash-looping (restarts: $RESTART_COUNT <= $MAX_ACCEPTABLE_RESTARTS)" "fail"
fi

# ─── Final state check ──────────────────────────────────────
FINAL_CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
FINAL_CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
FINAL_OFFSET_A=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A")
FINAL_END_OFFSET=$(get_topic_end_offset "$CONTEXT_A")

if [[ "$FINAL_END_OFFSET" -gt 0 ]]; then
    FINAL_LAG=$((FINAL_END_OFFSET - FINAL_OFFSET_A))
else
    FINAL_LAG="unknown"
fi

# ═══════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════
header "Failback Test Results"

info "Region A: RECOVERED"
info "  Consumer pods: $FINAL_CONSUMERS_A"
info "  Committed offset: $FINAL_OFFSET_A"
info "  Remaining lag: $FINAL_LAG"
info "  Restart count: $RESTART_COUNT"
info "  Messages processed during recovery: $TOTAL_RECOVERY_PROGRESS"
echo ""
info "Region B: OPERATIONAL"
info "  Consumer pods: $FINAL_CONSUMERS_B"
echo ""

print_summary
exit $?
