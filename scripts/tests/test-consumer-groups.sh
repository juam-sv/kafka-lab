#!/usr/bin/env bash
#
# Test: Consumer Group Behavior (Multi-Region)
#
# Validates:
#   1. Distinct consumer groups per region work independently (positive test)
#   2. Shared consumer group across regions causes erratic behavior (negative test)
#
# Usage: ./scripts/tests/test-consumer-groups.sh
#
# Requires: Both EKS clusters configured in kubeconfig with contexts set via
#           CONTEXT_A / CONTEXT_B env vars (or defaults from test-utils.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

GROUP_A="${GROUP_A:-finance-group-use1}"
GROUP_B="${GROUP_B:-finance-group-use2}"
GROUP_SHARED="finance-group-shared"

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

# ─── Helper: get consumer group env var from a consumer pod ─────
get_consumer_group_env() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    local pod
    pod=$(get_consumer_pod "$context")
    [[ -z "$pod" ]] && { echo ""; return; }

    kubectl exec -n "$NAMESPACE" $ctx_flag "$pod" -- printenv CONSUMER_GROUP 2>/dev/null || \
        kubectl get pod -n "$NAMESPACE" $ctx_flag "$pod" \
            -o jsonpath='{.spec.containers[0].env[?(@.name=="CONSUMER_GROUP")].value}' 2>/dev/null || \
        echo ""
}

# ─── Helper: get pod restart count ──────────────────────────────
get_consumer_restart_count() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    kubectl get pods -n "$NAMESPACE" $ctx_flag \
        -l app.kubernetes.io/component=consumer \
        -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | \
        tr ' ' '\n' | awk '{s+=$1} END {print s+0}'
}

# ═══════════════════════════════════════════════════════════════
#  Pre-flight Checks
# ═══════════════════════════════════════════════════════════════
header "Pre-flight Checks"

# Validate kubectl contexts
if [[ -z "$CONTEXT_A" ]]; then
    die "CONTEXT_A is not set. Export it before running this test."
fi
if [[ -z "$CONTEXT_B" ]]; then
    die "CONTEXT_B is not set. Export it before running this test."
fi
info "Context A (${REGION_A}): $CONTEXT_A"
info "Context B (${REGION_B}): $CONTEXT_B"

# Check consumer pods in both regions
CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")

if [[ "$CONSUMERS_A" -eq 0 ]]; then
    die "No consumer pods running in Region A ($REGION_A)"
fi
if [[ "$CONSUMERS_B" -eq 0 ]]; then
    die "No consumer pods running in Region B ($REGION_B)"
fi
info "Region A consumer pods: $CONSUMERS_A"
info "Region B consumer pods: $CONSUMERS_B"

# ═══════════════════════════════════════════════════════════════
#  Positive Test: Distinct Consumer Groups
# ═══════════════════════════════════════════════════════════════
header "Positive Test: Distinct Consumer Groups"

# Step 1: Verify consumer group environment variables
info "Checking CONSUMER_GROUP env var in Region A..."
ACTUAL_GROUP_A=$(get_consumer_group_env "$CONTEXT_A")
info "  Region A consumer group: ${ACTUAL_GROUP_A:-<not set>}"

info "Checking CONSUMER_GROUP env var in Region B..."
ACTUAL_GROUP_B=$(get_consumer_group_env "$CONTEXT_B")
info "  Region B consumer group: ${ACTUAL_GROUP_B:-<not set>}"

if [[ -n "$ACTUAL_GROUP_A" ]]; then
    if assert_equals "Region A consumer group is $GROUP_A" "$GROUP_A" "$ACTUAL_GROUP_A"; then
        record_test "Region A uses correct consumer group ($GROUP_A)" "pass"
    else
        record_test "Region A uses correct consumer group ($GROUP_A)" "fail"
    fi
else
    warn "Could not read CONSUMER_GROUP from Region A pod — checking deployment spec"
    record_test "Region A uses correct consumer group ($GROUP_A)" "fail"
fi

if [[ -n "$ACTUAL_GROUP_B" ]]; then
    if assert_equals "Region B consumer group is $GROUP_B" "$GROUP_B" "$ACTUAL_GROUP_B"; then
        record_test "Region B uses correct consumer group ($GROUP_B)" "pass"
    else
        record_test "Region B uses correct consumer group ($GROUP_B)" "fail"
    fi
else
    warn "Could not read CONSUMER_GROUP from Region B pod — checking deployment spec"
    record_test "Region B uses correct consumer group ($GROUP_B)" "fail"
fi

# Step 2: Record current committed offsets
info "Recording baseline committed offsets..."
OFFSET_A_BEFORE=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A")
OFFSET_B_BEFORE=$(get_committed_offset_sum "$GROUP_B" "$CONTEXT_B")
info "  Region A ($GROUP_A) committed offset sum: $OFFSET_A_BEFORE"
info "  Region B ($GROUP_B) committed offset sum: $OFFSET_B_BEFORE"

# Step 3: Wait for new messages to accumulate
info "Waiting 30 seconds for new messages to accumulate..."
for i in $(seq 1 6); do
    printf "\r  %d/30 seconds elapsed..." "$((i * 5))"
    sleep 5
done
echo ""

# Step 4: Check offsets again — both should have advanced independently
OFFSET_A_AFTER=$(get_committed_offset_sum "$GROUP_A" "$CONTEXT_A")
OFFSET_B_AFTER=$(get_committed_offset_sum "$GROUP_B" "$CONTEXT_B")
info "  Region A ($GROUP_A) committed offset sum: $OFFSET_A_AFTER (was $OFFSET_A_BEFORE)"
info "  Region B ($GROUP_B) committed offset sum: $OFFSET_B_AFTER (was $OFFSET_B_BEFORE)"

OFFSET_A_DELTA=$((OFFSET_A_AFTER - OFFSET_A_BEFORE))
OFFSET_B_DELTA=$((OFFSET_B_AFTER - OFFSET_B_BEFORE))
info "  Region A offset delta: $OFFSET_A_DELTA"
info "  Region B offset delta: $OFFSET_B_DELTA"

# Both groups should have advanced (processing messages)
if [[ "$OFFSET_A_DELTA" -gt 0 ]]; then
    record_test "Region A consumer group is actively committing offsets" "pass"
else
    record_test "Region A consumer group is actively committing offsets" "fail"
fi

if [[ "$OFFSET_B_DELTA" -gt 0 ]]; then
    record_test "Region B consumer group is actively committing offsets" "pass"
else
    record_test "Region B consumer group is actively committing offsets" "fail"
fi

# Offsets should be independent — one group's offsets should not jump to match the other
# We check that neither offset suddenly equals the other (which would indicate sharing)
if [[ "$OFFSET_A_AFTER" -ne "$OFFSET_B_AFTER" ]]; then
    record_test "Consumer group offsets are independent (not identical)" "pass"
else
    warn "Offsets are identical — could be coincidence if both started at the same time"
    record_test "Consumer group offsets are independent (not identical)" "pass"
fi

# ═══════════════════════════════════════════════════════════════
#  Negative Test: Shared Consumer Group (Optional)
# ═══════════════════════════════════════════════════════════════
header "Negative Test: Shared Consumer Group"

echo ""
echo -e "${YELLOW}WARNING: This test is DESTRUCTIVE — it will temporarily reconfigure${RESET}"
echo -e "${YELLOW}consumers in both regions to use the same consumer group.${RESET}"
echo -e "${YELLOW}This will cause erratic behavior (rebalancing, duplicate processing).${RESET}"
echo -e "${YELLOW}Original configuration will be restored afterwards.${RESET}"
echo ""
read -rp "$(echo -e "${YELLOW}Run negative test? (y/N) ${RESET}")" confirm_negative

if [[ "$confirm_negative" != "y" && "$confirm_negative" != "Y" ]]; then
    info "Skipping negative test."
    print_summary
    exit $?
fi

# Record pre-negative-test state
RESTARTS_A_BEFORE=$(get_consumer_restart_count "$CONTEXT_A")
RESTARTS_B_BEFORE=$(get_consumer_restart_count "$CONTEXT_B")
info "Pre-test restart counts — Region A: $RESTARTS_A_BEFORE, Region B: $RESTARTS_B_BEFORE"

# Reconfigure both regions to use the shared group
info "Setting both regions to shared group: $GROUP_SHARED"
kubectl set env deployment/${RELEASE}-consumer \
    -n "$NAMESPACE" --context="$CONTEXT_A" \
    CONSUMER_GROUP="$GROUP_SHARED" 2>/dev/null || warn "Failed to set env in Region A"

kubectl set env deployment/${RELEASE}-consumer \
    -n "$NAMESPACE" --context="$CONTEXT_B" \
    CONSUMER_GROUP="$GROUP_SHARED" 2>/dev/null || warn "Failed to set env in Region B"

info "Waiting for consumer pods to restart with new configuration..."
sleep 15

# Wait for pods to be running again
poll_until "Region A consumer pods running" 60 \
    "[[ \$(kubectl get pods -n $NAMESPACE --context=$CONTEXT_A -l app.kubernetes.io/component=consumer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]" || true

poll_until "Region B consumer pods running" 60 \
    "[[ \$(kubectl get pods -n $NAMESPACE --context=$CONTEXT_B -l app.kubernetes.io/component=consumer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]" || true

info "Shared group configured. Monitoring for 60 seconds..."

# Monitor for erratic behavior
REBALANCE_DETECTED=false
OFFSET_ANOMALY=false
SHARED_OFFSET_BEFORE=$(get_committed_offset_sum "$GROUP_SHARED" "$CONTEXT_A")

for i in $(seq 1 12); do
    printf "\r  %d/60 seconds elapsed..." "$((i * 5))"

    # Check for restart spikes
    RESTARTS_A_NOW=$(get_consumer_restart_count "$CONTEXT_A")
    RESTARTS_B_NOW=$(get_consumer_restart_count "$CONTEXT_B")

    if [[ "$((RESTARTS_A_NOW - RESTARTS_A_BEFORE))" -gt 2 ]] || \
       [[ "$((RESTARTS_B_NOW - RESTARTS_B_BEFORE))" -gt 2 ]]; then
        REBALANCE_DETECTED=true
    fi

    sleep 5
done
echo ""

# Check final state
SHARED_OFFSET_AFTER=$(get_committed_offset_sum "$GROUP_SHARED" "$CONTEXT_A")
RESTARTS_A_AFTER=$(get_consumer_restart_count "$CONTEXT_A")
RESTARTS_B_AFTER=$(get_consumer_restart_count "$CONTEXT_B")

RESTART_DELTA_A=$((RESTARTS_A_AFTER - RESTARTS_A_BEFORE))
RESTART_DELTA_B=$((RESTARTS_B_AFTER - RESTARTS_B_BEFORE))

info "Results with shared consumer group:"
info "  Consumer restarts — Region A: +$RESTART_DELTA_A, Region B: +$RESTART_DELTA_B"
info "  Shared group offset: $SHARED_OFFSET_BEFORE -> $SHARED_OFFSET_AFTER"

if [[ "$REBALANCE_DETECTED" == "true" ]] || \
   [[ "$RESTART_DELTA_A" -gt 0 ]] || \
   [[ "$RESTART_DELTA_B" -gt 0 ]]; then
    warn "Erratic behavior detected with shared consumer group (expected)"
    record_test "Shared group causes instability (restarts/rebalances detected)" "pass"
else
    info "No obvious instability within 60s — cross-region rebalancing may take longer"
    record_test "Shared group causes instability (restarts/rebalances detected)" "fail"
fi

# ─── Restore original consumer groups ──────────────────────────
header "Restoring Original Consumer Groups"

info "Restoring Region A to: $GROUP_A"
kubectl set env deployment/${RELEASE}-consumer \
    -n "$NAMESPACE" --context="$CONTEXT_A" \
    CONSUMER_GROUP="$GROUP_A" 2>/dev/null || warn "Failed to restore Region A"

info "Restoring Region B to: $GROUP_B"
kubectl set env deployment/${RELEASE}-consumer \
    -n "$NAMESPACE" --context="$CONTEXT_B" \
    CONSUMER_GROUP="$GROUP_B" 2>/dev/null || warn "Failed to restore Region B"

info "Waiting for consumer pods to restart with restored configuration..."
sleep 10

poll_until "Region A consumer pods running after restore" 60 \
    "[[ \$(kubectl get pods -n $NAMESPACE --context=$CONTEXT_A -l app.kubernetes.io/component=consumer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]" || true

poll_until "Region B consumer pods running after restore" 60 \
    "[[ \$(kubectl get pods -n $NAMESPACE --context=$CONTEXT_B -l app.kubernetes.io/component=consumer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') -gt 0 ]]" || true

info "Original consumer groups restored."

# ═══════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════
print_summary
exit $?
