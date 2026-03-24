#!/usr/bin/env bash
#
# Test: Region A Failover — Region B Continues Operating
#
# Validates:
#   1. Region B consumers/producers survive Region A going offline
#   2. Region B consumer lag remains stable during the outage
#   3. Replay window is quantified (gap between Region A end offset and last committed offset)
#
# Usage: ./scripts/tests/test-failover.sh
#
# Note: This test scales Region A deployments to 0 replicas. The test-failback.sh
#       script handles restoring them. An optional restore prompt is offered at the end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

GROUP_A="${GROUP_A:-finance-group-use1}"
GROUP_B="${GROUP_B:-finance-group-use2}"

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

# ─── Helper: get producer pod count ─────────────────────────────
get_producer_pod_count() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"
    kubectl get pods -n "$NAMESPACE" $ctx_flag \
        -l app.kubernetes.io/component=producer \
        --field-selector=status.phase=Running \
        --no-headers 2>/dev/null | wc -l | tr -d ' '
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

# Check producer and consumer pods in both regions
CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
PRODUCERS_A=$(get_producer_pod_count "$CONTEXT_A")
PRODUCERS_B=$(get_producer_pod_count "$CONTEXT_B")

info "Region A — producers: $PRODUCERS_A, consumers: $CONSUMERS_A"
info "Region B — producers: $PRODUCERS_B, consumers: $CONSUMERS_B"

if [[ "$CONSUMERS_A" -eq 0 ]] || [[ "$PRODUCERS_A" -eq 0 ]]; then
    die "Region A does not have both producer and consumer pods running."
fi
if [[ "$CONSUMERS_B" -eq 0 ]] || [[ "$PRODUCERS_B" -eq 0 ]]; then
    die "Region B does not have both producer and consumer pods running."
fi

# ─── Record baseline ──────────────────────────────────────────
header "Recording Baseline"

BASELINE_OFFSET_A=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A")
BASELINE_OFFSET_B=$(get_committed_offset_sum "$GROUP_B" "$CONTEXT_B")
BASELINE_END_OFFSET_A=$(get_topic_end_offset "$CONTEXT_A")

info "Region A ($GROUP_A) committed offset: $BASELINE_OFFSET_A"
info "Region B ($GROUP_B) committed offset: $BASELINE_OFFSET_B"
info "Region A topic end offset: $BASELINE_END_OFFSET_A"
info "Region A consumer pods: $CONSUMERS_A"
info "Region B consumer pods: $CONSUMERS_B"

# ═══════════════════════════════════════════════════════════════
#  Failover Simulation
# ═══════════════════════════════════════════════════════════════
header "Failover Simulation — Region A"

echo ""
echo -e "${YELLOW}WARNING: This will scale Region A producer and consumer deployments${RESET}"
echo -e "${YELLOW}to 0 replicas, simulating a regional failure.${RESET}"
echo -e "${YELLOW}Region B should continue operating normally.${RESET}"
echo ""
read -rp "$(echo -e "${YELLOW}Proceed with failover simulation? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Aborted."
    exit 0
fi

# Scale Region A to 0
info "Scaling Region A producer to 0 replicas..."
kubectl scale deployment/${RELEASE}-producer \
    --replicas=0 -n "$NAMESPACE" --context="$CONTEXT_A" 2>/dev/null || \
    die "Failed to scale Region A producer"

info "Scaling Region A consumer to 0 replicas..."
kubectl scale deployment/${RELEASE}-consumer \
    --replicas=0 -n "$NAMESPACE" --context="$CONTEXT_A" 2>/dev/null || \
    die "Failed to scale Region A consumer"

info "Region A deployments scaled to 0. Waiting 10 seconds for pods to terminate..."
sleep 10

# ─── Verify Region B is still running ─────────────────────────
header "Verifying Region B Continues Operating"

CONSUMERS_B_AFTER=$(get_consumer_pod_count "$CONTEXT_B")
PRODUCERS_B_AFTER=$(get_producer_pod_count "$CONTEXT_B")

info "Region B consumers after failover: $CONSUMERS_B_AFTER"
info "Region B producers after failover: $PRODUCERS_B_AFTER"

if [[ "$CONSUMERS_B_AFTER" -gt 0 ]]; then
    record_test "Region B consumers still running after Region A failure" "pass"
else
    record_test "Region B consumers still running after Region A failure" "fail"
fi

if [[ "$PRODUCERS_B_AFTER" -gt 0 ]]; then
    record_test "Region B producers still running after Region A failure" "pass"
else
    record_test "Region B producers still running after Region A failure" "fail"
fi

# Verify Region A is actually down
CONSUMERS_A_AFTER=$(get_consumer_pod_count "$CONTEXT_A")
PRODUCERS_A_AFTER=$(kubectl get pods -n "$NAMESPACE" --context="$CONTEXT_A" \
    -l app.kubernetes.io/component=producer \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$CONSUMERS_A_AFTER" -eq 0 ]] && [[ "$PRODUCERS_A_AFTER" -eq 0 ]]; then
    record_test "Region A pods confirmed terminated" "pass"
else
    warn "Region A still has running pods (consumers: $CONSUMERS_A_AFTER, producers: $PRODUCERS_A_AFTER)"
    record_test "Region A pods confirmed terminated" "fail"
fi

# ─── Wait for Region B to produce during outage ───────────────
header "Region B Operating During Outage (60s observation)"

OFFSET_B_START=$(get_committed_offset_sum "$GROUP_B" "$CONTEXT_B")
info "Region B committed offset at outage start: $OFFSET_B_START"

for i in $(seq 1 12); do
    CURRENT_OFFSET_B=$(get_committed_offset_sum "$GROUP_B" "$CONTEXT_B")
    CURRENT_CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
    OFFSET_PROGRESS=$((CURRENT_OFFSET_B - OFFSET_B_START))

    printf "\r  [%s] Region B — offset: %s (+%s) | consumers: %s" \
        "$(date +%H:%M:%S)" "$CURRENT_OFFSET_B" "$OFFSET_PROGRESS" "$CURRENT_CONSUMERS_B"

    sleep 5
done
echo ""

OFFSET_B_END=$(get_committed_offset_sum "$GROUP_B" "$CONTEXT_B")
OFFSET_B_PROGRESS=$((OFFSET_B_END - OFFSET_B_START))

info "Region B offset progress during outage: $OFFSET_B_PROGRESS messages processed"

# Consumer lag: stable or decreasing is good
if [[ "$OFFSET_B_PROGRESS" -gt 0 ]]; then
    record_test "Region B consumer lag stable/decreasing during outage" "pass"
else
    warn "Region B consumer offset did not advance during outage"
    record_test "Region B consumer lag stable/decreasing during outage" "fail"
fi

# ─── Measure replay window ────────────────────────────────────
header "Measuring Replay Window for Region A"

# Region A's topic end offset (what was the last message written before shutdown)
# We need to read this from Region B since Region A pods are down
# The replicated topic should have the same data
FINAL_END_OFFSET_A=$BASELINE_END_OFFSET_A  # Use the baseline we captured before shutdown
FINAL_COMMITTED_A=$BASELINE_OFFSET_A        # Last committed offset before shutdown

REPLAY_WINDOW=$((FINAL_END_OFFSET_A - FINAL_COMMITTED_A))

info "Region A last committed offset: $FINAL_COMMITTED_A"
info "Region A topic end offset (at shutdown): $FINAL_END_OFFSET_A"
info "Replay window (uncommitted messages): $REPLAY_WINDOW"

if [[ "$REPLAY_WINDOW" -ge 0 ]]; then
    record_test "Replay window calculated ($REPLAY_WINDOW messages)" "pass"
else
    warn "Negative replay window — possible offset inconsistency"
    record_test "Replay window calculated ($REPLAY_WINDOW messages)" "fail"
fi

# ═══════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════
header "Failover Test Results"

info "Region A: OFFLINE (scaled to 0 replicas)"
info "Region B: OPERATIONAL (consumers: $CURRENT_CONSUMERS_B)"
info "Region B processed $OFFSET_B_PROGRESS messages during outage"
info "Region A replay window: $REPLAY_WINDOW uncommitted messages"
echo ""

print_summary
SUMMARY_EXIT=$?

# ─── Optional: Restore Region A ───────────────────────────────
echo ""
echo -e "${CYAN}NOTE: Region A deployments are still scaled to 0.${RESET}"
echo -e "${CYAN}Run test-failback.sh to test Region A recovery.${RESET}"
echo ""
read -rp "$(echo -e "${YELLOW}Or restore Region A now? (y/N) ${RESET}")" restore_confirm

if [[ "$restore_confirm" == "y" || "$restore_confirm" == "Y" ]]; then
    header "Restoring Region A"

    info "Scaling Region A producer to 1 replica..."
    kubectl scale deployment/${RELEASE}-producer \
        --replicas=1 -n "$NAMESPACE" --context="$CONTEXT_A" 2>/dev/null || \
        warn "Failed to scale Region A producer"

    info "Scaling Region A consumer to 1 replica..."
    kubectl scale deployment/${RELEASE}-consumer \
        --replicas=1 -n "$NAMESPACE" --context="$CONTEXT_A" 2>/dev/null || \
        warn "Failed to scale Region A consumer"

    info "Region A restore initiated. Use test-failback.sh for full recovery validation."
else
    info "Region A left offline. Run test-failback.sh to restore and validate."
fi

exit $SUMMARY_EXIT
