#!/usr/bin/env bash
#
# Test: Loop Prevention in Bi-directional Replication
#
# Validates that MSK replicators do NOT create infinite message loops:
#   1. Messages produced in A replicate to B exactly once (no echo back to A)
#   2. Messages produced in B replicate to A exactly once (no echo back to B)
#   3. After bidirectional produce, both regions stabilize at the correct total
#
# Usage: ./scripts/tests/test-loop-prevention.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

# ─── Configuration ────────────────────────────────────────────────
BATCH_A=50
BATCH_B=30
EXPECTED_TOTAL=$((BATCH_A + BATCH_B))   # 80
PARTITIONS=3
SETTLE_WAIT=30     # seconds to wait for potential loop to manifest
TEST_TOPIC="loop-test-$(date +%s)"

# ─── Helper: Create topic via kubectl exec ────────────────────────
create_topic() {
    local region="$1"
    local topic="$2"
    local partitions="$3"
    local context="${4:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    local pod
    pod=$(get_producer_pod "$context")
    [[ -z "$pod" ]] && die "No producer pod found for context=$context"

    info "Creating topic $topic ($partitions partitions) in $region"

    kubectl exec -n "$NAMESPACE" $ctx_flag "$pod" -- python -c "
import os
from confluent_kafka.admin import AdminClient, NewTopic
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', '$region')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
a = AdminClient({
    'bootstrap.servers': os.environ['KAFKA_BROKER'],
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'OAUTHBEARER',
    'oauth_cb': oauth_cb,
})
topic = NewTopic('$topic', num_partitions=$partitions, replication_factor=3)
fs = a.create_topics([topic])
for t, f in fs.items():
    f.result()
    print(f'Created topic {t}')
" 2>/dev/null
}

# ─── Helper: Get and validate message count ───────────────────────
check_count() {
    local region="$1"
    local topic="$2"
    local context="${3:-}"

    local count
    count=$(get_topic_message_count "$region" "$topic" "$context")
    echo "$count" | tr -d '[:space:]'
}

# ─── Step 1: Pre-flight checks ───────────────────────────────────
header "Pre-flight Checks"

info "Checking MSK replicators in $REGION_A..."
REPLICATORS_A=$(aws kafka list-replicators --region "$REGION_A" \
    --query 'Replicators[?ReplicatorState==`RUNNING`].ReplicatorName' \
    --output text 2>/dev/null || echo "")
if [[ -z "$REPLICATORS_A" ]]; then
    die "No RUNNING replicators found in $REGION_A"
fi
info "Replicators in $REGION_A: $REPLICATORS_A"

info "Checking MSK replicators in $REGION_B..."
REPLICATORS_B=$(aws kafka list-replicators --region "$REGION_B" \
    --query 'Replicators[?ReplicatorState==`RUNNING`].ReplicatorName' \
    --output text 2>/dev/null || echo "")
if [[ -z "$REPLICATORS_B" ]]; then
    die "No RUNNING replicators found in $REGION_B"
fi
info "Replicators in $REGION_B: $REPLICATORS_B"

# Verify kubectl connectivity to both clusters
POD_A=$(get_producer_pod "$CONTEXT_A")
[[ -z "$POD_A" ]] && die "Cannot find producer pod in Region A (context=$CONTEXT_A)"
info "Region A producer pod: $POD_A"

POD_B=$(get_producer_pod "$CONTEXT_B")
[[ -z "$POD_B" ]] && die "Cannot find producer pod in Region B (context=$CONTEXT_B)"
info "Region B producer pod: $POD_B"

echo ""
info "Test topic: $TEST_TOPIC"
info "Batch A: $BATCH_A messages | Batch B: $BATCH_B messages"
info "Expected total after both batches: $EXPECTED_TOTAL"
info "Settle wait between checks: ${SETTLE_WAIT}s"
echo ""
read -rp "$(echo -e "${YELLOW}Continue with loop prevention test? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Aborted."
    exit 0
fi

# ─── Step 2: Create test topic in Region A ────────────────────────
header "Phase 1: Produce in Region A, Verify No Loop-back"

create_topic "$REGION_A" "$TEST_TOPIC" "$PARTITIONS" "$CONTEXT_A"

# ─── Step 3: Produce batch to Region A ────────────────────────────
info "Producing $BATCH_A messages to $REGION_A"
produce_test_messages "$REGION_A" "$TEST_TOPIC" "$BATCH_A" "$CONTEXT_A"

# Verify source count
COUNT_A=$(check_count "$REGION_A" "$TEST_TOPIC" "$CONTEXT_A")
info "Region A count after produce: $COUNT_A"

if assert_equals "Region A initial count" "$BATCH_A" "$COUNT_A"; then
    record_test "Phase 1 — Region A has $BATCH_A messages after produce" "pass"
else
    record_test "Phase 1 — Region A count (expected $BATCH_A, got $COUNT_A)" "fail"
fi

# ─── Step 4: Wait for replication to Region B ─────────────────────
echo ""
if wait_for_replication "A->B replication" "$REGION_B" "$TEST_TOPIC" "$BATCH_A" 120 "$CONTEXT_B"; then
    record_test "Phase 1 — A->B replication completed" "pass"
else
    record_test "Phase 1 — A->B replication timed out" "fail"
fi
echo ""

COUNT_B=$(check_count "$REGION_B" "$TEST_TOPIC" "$CONTEXT_B")
info "Region B count after replication: $COUNT_B"

if assert_equals "Region B count after A->B replication" "$BATCH_A" "$COUNT_B"; then
    record_test "Phase 1 — Region B has exactly $BATCH_A messages" "pass"
else
    record_test "Phase 1 — Region B count (expected $BATCH_A, got $COUNT_B)" "fail"
fi

# ─── Step 5: Record high-water mark and wait for potential loop ───
header "Phase 2: Loop Detection (waiting ${SETTLE_WAIT}s)"

info "Region A high-water mark: $COUNT_A (should remain $BATCH_A)"
info "Region B count: $COUNT_B (should remain $BATCH_A)"
info "Waiting ${SETTLE_WAIT}s for potential loop-back to manifest..."

for i in $(seq 1 "$SETTLE_WAIT"); do
    printf "\r  Settling... %s/%ss" "$i" "$SETTLE_WAIT"
    sleep 1
done
echo ""

# ─── Step 6: Re-check both regions — counts must be stable ───────
COUNT_A_AFTER=$(check_count "$REGION_A" "$TEST_TOPIC" "$CONTEXT_A")
info "Region A count after settle: $COUNT_A_AFTER (expected $BATCH_A)"

if assert_equals "Region A stable after settle" "$BATCH_A" "$COUNT_A_AFTER"; then
    record_test "Phase 2 — Region A stable at $BATCH_A (no loop-back)" "pass"
else
    warn "LOOP DETECTED: Region A grew from $BATCH_A to $COUNT_A_AFTER"
    record_test "Phase 2 — Region A loop detected ($BATCH_A -> $COUNT_A_AFTER)" "fail"
fi

COUNT_B_AFTER=$(check_count "$REGION_B" "$TEST_TOPIC" "$CONTEXT_B")
info "Region B count after settle: $COUNT_B_AFTER (expected $BATCH_A)"

if assert_equals "Region B stable after settle" "$BATCH_A" "$COUNT_B_AFTER"; then
    record_test "Phase 2 — Region B stable at $BATCH_A (no loop-back)" "pass"
else
    warn "LOOP DETECTED: Region B grew from $BATCH_A to $COUNT_B_AFTER"
    record_test "Phase 2 — Region B loop detected ($BATCH_A -> $COUNT_B_AFTER)" "fail"
fi

# ─── Step 7: Produce batch in Region B ────────────────────────────
header "Phase 3: Produce in Region B, Verify Bidirectional Stability"

info "Producing $BATCH_B messages to $REGION_B"
produce_test_messages "$REGION_B" "$TEST_TOPIC" "$BATCH_B" "$CONTEXT_B"

COUNT_B_POST=$(check_count "$REGION_B" "$TEST_TOPIC" "$CONTEXT_B")
info "Region B count after second produce: $COUNT_B_POST (expected $EXPECTED_TOTAL)"

if assert_equals "Region B after second produce" "$EXPECTED_TOTAL" "$COUNT_B_POST"; then
    record_test "Phase 3 — Region B has $EXPECTED_TOTAL after both batches" "pass"
else
    record_test "Phase 3 — Region B count (expected $EXPECTED_TOTAL, got $COUNT_B_POST)" "fail"
fi

# ─── Step 8: Wait for replication of batch B to Region A ──────────
echo ""
if wait_for_replication "B->A replication" "$REGION_A" "$TEST_TOPIC" "$EXPECTED_TOTAL" 120 "$CONTEXT_A"; then
    record_test "Phase 3 — B->A replication completed" "pass"
else
    record_test "Phase 3 — B->A replication timed out" "fail"
fi
echo ""

COUNT_A_POST=$(check_count "$REGION_A" "$TEST_TOPIC" "$CONTEXT_A")
info "Region A count after B->A replication: $COUNT_A_POST (expected $EXPECTED_TOTAL)"

if assert_equals "Region A after B->A replication" "$EXPECTED_TOTAL" "$COUNT_A_POST"; then
    record_test "Phase 3 — Region A has $EXPECTED_TOTAL after both batches" "pass"
else
    record_test "Phase 3 — Region A count (expected $EXPECTED_TOTAL, got $COUNT_A_POST)" "fail"
fi

# ─── Step 9: Final settle — verify no further growth ─────────────
header "Phase 4: Final Stability Check (waiting ${SETTLE_WAIT}s)"

info "Both regions should stabilize at $EXPECTED_TOTAL"
info "Waiting ${SETTLE_WAIT}s for potential secondary loop..."

for i in $(seq 1 "$SETTLE_WAIT"); do
    printf "\r  Settling... %s/%ss" "$i" "$SETTLE_WAIT"
    sleep 1
done
echo ""

FINAL_A=$(check_count "$REGION_A" "$TEST_TOPIC" "$CONTEXT_A")
info "Region A final count: $FINAL_A (expected $EXPECTED_TOTAL)"

if assert_equals "Region A final stable" "$EXPECTED_TOTAL" "$FINAL_A"; then
    record_test "Phase 4 — Region A final stable at $EXPECTED_TOTAL" "pass"
else
    warn "LOOP DETECTED: Region A at $FINAL_A (expected $EXPECTED_TOTAL)"
    record_test "Phase 4 — Region A loop detected (expected $EXPECTED_TOTAL, got $FINAL_A)" "fail"
fi

FINAL_B=$(check_count "$REGION_B" "$TEST_TOPIC" "$CONTEXT_B")
info "Region B final count: $FINAL_B (expected $EXPECTED_TOTAL)"

if assert_equals "Region B final stable" "$EXPECTED_TOTAL" "$FINAL_B"; then
    record_test "Phase 4 — Region B final stable at $EXPECTED_TOTAL" "pass"
else
    warn "LOOP DETECTED: Region B at $FINAL_B (expected $EXPECTED_TOTAL)"
    record_test "Phase 4 — Region B loop detected (expected $EXPECTED_TOTAL, got $FINAL_B)" "fail"
fi

# ─── Summary ──────────────────────────────────────────────────────
print_summary
