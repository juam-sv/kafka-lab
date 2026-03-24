#!/usr/bin/env bash
#
# Test: Baseline A->B and B->A Replication Correctness
#
# Validates:
#   1. Messages produced in Region A replicate to Region B with all keys intact
#   2. Per-partition ordering is preserved (sequence numbers monotonically increasing)
#   3. Reverse direction (B->A) works identically
#
# Usage: ./scripts/tests/test-replication-baseline.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

# ─── Configuration ────────────────────────────────────────────────
MSG_COUNT=100
PARTITIONS=3
TEST_TOPIC="repl-test-$(date +%s)"

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

# ─── Helper: Verify messages ─────────────────────────────────────
# Consumes messages and verifies count, keys, and per-partition ordering.
# Outputs pass/fail via record_test.
verify_messages() {
    local direction="$1"      # e.g. "A->B"
    local region="$2"
    local topic="$3"
    local expected_count="$4"
    local context="${5:-}"

    info "Consuming messages from $region for verification ($direction)"

    local consumed
    consumed=$(consume_test_messages "$region" "$topic" "$expected_count" 60 "$context")

    # --- Check 1: Message count ---
    local actual_count
    actual_count=$(echo "$consumed" | grep -c '^{' || true)

    if assert_equals "$direction message count" "$expected_count" "$actual_count"; then
        record_test "$direction — message count ($expected_count)" "pass"
    else
        record_test "$direction — message count (expected $expected_count, got $actual_count)" "fail"
        return 1
    fi

    # --- Check 2: All keys present ---
    local missing_keys=0
    for i in $(seq 0 $((expected_count - 1))); do
        local key="test-key-$i"
        if ! echo "$consumed" | python3 -c "
import sys, json
msgs = [json.loads(l) for l in sys.stdin if l.strip().startswith('{')]
keys = [m['key'] for m in msgs]
sys.exit(0 if '$key' in keys else 1)
" 2>/dev/null; then
            missing_keys=$((missing_keys + 1))
        fi
    done

    if [[ "$missing_keys" -eq 0 ]]; then
        record_test "$direction — all keys present" "pass"
    else
        record_test "$direction — keys missing ($missing_keys of $expected_count)" "fail"
    fi

    # --- Check 3: Per-partition ordering (sequence numbers monotonically increasing) ---
    local ordering_ok
    ordering_ok=$(echo "$consumed" | python3 -c "
import sys, json
from collections import defaultdict

msgs = [json.loads(l) for l in sys.stdin if l.strip().startswith('{')]
partitions = defaultdict(list)
for m in msgs:
    partitions[m['partition']].append(m['value']['seq'])

all_ok = True
for pid, seqs in sorted(partitions.items()):
    for i in range(1, len(seqs)):
        if seqs[i] <= seqs[i-1]:
            print(f'FAIL: partition {pid} ordering violated at index {i}: {seqs[i-1]} -> {seqs[i]}')
            all_ok = False
            break

if all_ok:
    print('OK')
" 2>/dev/null)

    if [[ "$ordering_ok" == "OK" ]]; then
        record_test "$direction — per-partition ordering preserved" "pass"
    else
        warn "Ordering issue: $ordering_ok"
        record_test "$direction — per-partition ordering violated" "fail"
    fi
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
info "Message count: $MSG_COUNT"
info "Partitions: $PARTITIONS"
echo ""
read -rp "$(echo -e "${YELLOW}Continue with replication baseline test? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Aborted."
    exit 0
fi

# ─── Step 2: Create test topic in Region A ────────────────────────
header "Phase 1: A -> B Replication"

info "Creating test topic in $REGION_A"
create_topic "$REGION_A" "$TEST_TOPIC" "$PARTITIONS" "$CONTEXT_A"

# ─── Step 3: Produce messages to Region A ─────────────────────────
info "Producing $MSG_COUNT messages to $REGION_A"
produce_test_messages "$REGION_A" "$TEST_TOPIC" "$MSG_COUNT" "$CONTEXT_A"

# Verify messages arrived in Region A
COUNT_A=$(get_topic_message_count "$REGION_A" "$TEST_TOPIC" "$CONTEXT_A")
COUNT_A=$(echo "$COUNT_A" | tr -d '[:space:]')
info "Messages in Region A after produce: $COUNT_A"

if assert_equals "Region A source message count" "$MSG_COUNT" "$COUNT_A"; then
    record_test "A->B — source produce ($MSG_COUNT messages)" "pass"
else
    record_test "A->B — source produce (expected $MSG_COUNT, got $COUNT_A)" "fail"
fi

# ─── Step 4: Wait for replication to Region B ─────────────────────
echo ""
if wait_for_replication "A->B replication" "$REGION_B" "$TEST_TOPIC" "$MSG_COUNT" 120 "$CONTEXT_B"; then
    record_test "A->B — replication completed within timeout" "pass"
else
    record_test "A->B — replication timed out" "fail"
fi
echo ""

# ─── Step 5: Verify messages in Region B ──────────────────────────
verify_messages "A->B" "$REGION_B" "$TEST_TOPIC" "$MSG_COUNT" "$CONTEXT_B"

# ─── Step 6: Reverse — Produce in Region B, verify in Region A ───
header "Phase 2: B -> A Replication"

REVERSE_TOPIC="repl-test-reverse-$(date +%s)"
info "Creating reverse test topic: $REVERSE_TOPIC"
create_topic "$REGION_B" "$REVERSE_TOPIC" "$PARTITIONS" "$CONTEXT_B"

info "Producing $MSG_COUNT messages to $REGION_B"
produce_test_messages "$REGION_B" "$REVERSE_TOPIC" "$MSG_COUNT" "$CONTEXT_B"

# Verify messages arrived in Region B
COUNT_B=$(get_topic_message_count "$REGION_B" "$REVERSE_TOPIC" "$CONTEXT_B")
COUNT_B=$(echo "$COUNT_B" | tr -d '[:space:]')
info "Messages in Region B after produce: $COUNT_B"

if assert_equals "Region B source message count" "$MSG_COUNT" "$COUNT_B"; then
    record_test "B->A — source produce ($MSG_COUNT messages)" "pass"
else
    record_test "B->A — source produce (expected $MSG_COUNT, got $COUNT_B)" "fail"
fi

# Wait for replication to Region A
echo ""
if wait_for_replication "B->A replication" "$REGION_A" "$REVERSE_TOPIC" "$MSG_COUNT" 120 "$CONTEXT_A"; then
    record_test "B->A — replication completed within timeout" "pass"
else
    record_test "B->A — replication timed out" "fail"
fi
echo ""

# Verify messages in Region A
verify_messages "B->A" "$REGION_A" "$REVERSE_TOPIC" "$MSG_COUNT" "$CONTEXT_A"

# ─── Summary ──────────────────────────────────────────────────────
print_summary
