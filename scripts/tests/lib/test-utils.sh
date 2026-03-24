#!/usr/bin/env bash
#
# Shared test utilities for MSK multi-region replication tests.
# Source this file in test scripts: source "$(dirname "$0")/lib/test-utils.sh"

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Output helpers ──────────────────────────────────────────────
header() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo -e "${CYAN}  $*${RESET}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"
}

info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET} $*"; }
pass()  { echo -e "${GREEN}[PASS]${RESET} $*"; }

die() {
    fail "$*"
    exit 1
}

# ─── Defaults ────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-default}"
RELEASE="${RELEASE:-kafka-lab}"
REGION_A="${REGION_A:-us-east-1}"
REGION_B="${REGION_B:-us-east-2}"
TOPIC="${TOPIC:-financial.transactions}"

# Cluster context names — override if different
CONTEXT_A="${CONTEXT_A:-}"
CONTEXT_B="${CONTEXT_B:-}"

# ─── Assertions ──────────────────────────────────────────────────
assert_equals() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$description: expected=$expected actual=$actual"
        return 0
    else
        fail "$description: expected=$expected actual=$actual"
        return 1
    fi
}

assert_greater_than() {
    local description="$1" threshold="$2" actual="$3"
    if [[ "$actual" -gt "$threshold" ]]; then
        pass "$description: $actual > $threshold"
        return 0
    else
        fail "$description: $actual <= $threshold"
        return 1
    fi
}

assert_less_than_or_equal() {
    local description="$1" threshold="$2" actual="$3"
    if [[ "$actual" -le "$threshold" ]]; then
        pass "$description: $actual <= $threshold"
        return 0
    else
        fail "$description: $actual > $threshold"
        return 1
    fi
}

# ─── Poll until condition ────────────────────────────────────────
# Usage: poll_until "description" <timeout_seconds> <command>
# Returns 0 if command succeeds within timeout, 1 otherwise.
poll_until() {
    local description="$1"
    local timeout="$2"
    shift 2
    local start_time
    start_time=$(date +%s)

    while true; do
        if eval "$@" 2>/dev/null; then
            return 0
        fi
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ "$elapsed" -ge "$timeout" ]]; then
            fail "Timed out after ${timeout}s: $description"
            return 1
        fi
        sleep 5
    done
}

# ─── Kubernetes helpers ──────────────────────────────────────────
# Get a producer pod name in a given context
get_producer_pod() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"
    kubectl get pods -n "$NAMESPACE" $ctx_flag \
        -l app.kubernetes.io/component=producer \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Get a consumer pod name in a given context
get_consumer_pod() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"
    kubectl get pods -n "$NAMESPACE" $ctx_flag \
        -l app.kubernetes.io/component=consumer \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ─── Kafka helpers (via pod exec) ────────────────────────────────
# Get the message count (high-water mark sum) for a topic in a given region.
# Uses a producer pod to exec Python since it has confluent-kafka + MSK auth.
get_topic_message_count() {
    local region="$1"
    local topic="$2"
    local context="${3:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    local pod
    pod=$(get_producer_pod "$context")
    [[ -z "$pod" ]] && { warn "No producer pod found for context=$context"; echo "0"; return; }

    kubectl exec -n "$NAMESPACE" $ctx_flag "$pod" -- python -c "
import os
from confluent_kafka import Consumer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', '$region')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
c = Consumer({
    'bootstrap.servers': os.environ['KAFKA_BROKER'],
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'OAUTHBEARER',
    'oauth_cb': oauth_cb,
    'group.id': 'test-counter-temp',
    'auto.offset.reset': 'earliest',
})
md = c.list_topics(topic='$topic', timeout=10)
if '$topic' not in md.topics:
    print(0)
else:
    parts = md.topics['$topic'].partitions
    total = 0
    from confluent_kafka import TopicPartition
    for pid in parts:
        lo, hi = c.get_watermark_offsets(TopicPartition('$topic', pid), timeout=10)
        total += hi - lo
    print(total)
c.close()
" 2>/dev/null || echo "0"
}

# Produce N test messages to a topic in a given region.
# Messages contain a sequence number and source_region for verification.
produce_test_messages() {
    local region="$1"
    local topic="$2"
    local count="$3"
    local context="${4:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    local pod
    pod=$(get_producer_pod "$context")
    [[ -z "$pod" ]] && die "No producer pod found for context=$context"

    info "Producing $count test messages to $topic in $region"

    kubectl exec -n "$NAMESPACE" $ctx_flag "$pod" -- python -c "
import os, json, uuid, time
from confluent_kafka import Producer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', '$region')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
p = Producer({
    'bootstrap.servers': os.environ['KAFKA_BROKER'],
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'OAUTHBEARER',
    'oauth_cb': oauth_cb,
})
for i in range($count):
    key = f'test-key-{i}'
    payload = json.dumps({
        'seq': i,
        'source_region': '$region',
        'test_id': '$topic',
        'transaction_id': str(uuid.uuid4()),
        'timestamp': time.time(),
    })
    p.produce('$topic', payload.encode(), key=key.encode())
    if i % 50 == 0:
        p.flush()
p.flush()
print(f'Produced $count messages to $topic')
" 2>/dev/null
}

# Consume messages from a topic and return them as JSON lines.
consume_test_messages() {
    local region="$1"
    local topic="$2"
    local expected_count="$3"
    local timeout_sec="${4:-30}"
    local context="${5:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"

    local pod
    pod=$(get_producer_pod "$context")
    [[ -z "$pod" ]] && die "No producer pod found for context=$context"

    kubectl exec -n "$NAMESPACE" $ctx_flag "$pod" -- python -c "
import os, json, time
from confluent_kafka import Consumer, TopicPartition
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', '$region')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
c = Consumer({
    'bootstrap.servers': os.environ['KAFKA_BROKER'],
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'OAUTHBEARER',
    'oauth_cb': oauth_cb,
    'group.id': 'test-verifier-$topic',
    'auto.offset.reset': 'earliest',
    'enable.auto.commit': False,
})
c.subscribe(['$topic'])
messages = []
deadline = time.time() + $timeout_sec
while len(messages) < $expected_count and time.time() < deadline:
    msg = c.poll(1.0)
    if msg is None:
        continue
    if msg.error():
        continue
    messages.append({
        'key': msg.key().decode() if msg.key() else None,
        'value': json.loads(msg.value().decode()),
        'partition': msg.partition(),
        'offset': msg.offset(),
    })
c.close()
for m in messages:
    print(json.dumps(m))
" 2>/dev/null
}

# Wait for replication: poll remote cluster until topic has expected count.
wait_for_replication() {
    local description="$1"
    local region="$2"
    local topic="$3"
    local expected_count="$4"
    local timeout="${5:-120}"
    local context="${6:-}"

    info "Waiting for replication: $description (expecting $expected_count messages, timeout ${timeout}s)"

    local start_time
    start_time=$(date +%s)

    while true; do
        local count
        count=$(get_topic_message_count "$region" "$topic" "$context")
        count=$(echo "$count" | tr -d '[:space:]')

        if [[ "$count" -ge "$expected_count" ]]; then
            local elapsed=$(( $(date +%s) - start_time ))
            info "Replication complete: $count messages in ${elapsed}s"
            return 0
        fi

        local elapsed=$(( $(date +%s) - start_time ))
        if [[ "$elapsed" -ge "$timeout" ]]; then
            fail "Replication timeout after ${timeout}s: got $count, expected $expected_count"
            return 1
        fi

        printf "\r  Waiting... %s/%s messages (%ss elapsed)" "$count" "$expected_count" "$elapsed"
        sleep 5
    done
}

# ─── FIS helpers ─────────────────────────────────────────────────
# Start an FIS experiment and return the experiment ID.
start_fis_experiment() {
    local template_id="$1"
    local region="$2"

    info "Starting FIS experiment: template=$template_id region=$region"
    local result
    result=$(aws fis start-experiment \
        --experiment-template-id "$template_id" \
        --region "$region" \
        --output json 2>/dev/null)

    local experiment_id
    experiment_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['experiment']['id'])")
    info "FIS experiment started: $experiment_id"
    echo "$experiment_id"
}

# Wait for an FIS experiment to complete.
wait_for_fis_experiment() {
    local experiment_id="$1"
    local region="$2"
    local timeout="${3:-600}"

    info "Waiting for FIS experiment $experiment_id to complete (timeout ${timeout}s)"

    local start_time
    start_time=$(date +%s)

    while true; do
        local status
        status=$(aws fis get-experiment \
            --id "$experiment_id" \
            --region "$region" \
            --query 'experiment.state.status' \
            --output text 2>/dev/null)

        case "$status" in
            completed) info "FIS experiment completed successfully"; return 0 ;;
            stopped)   warn "FIS experiment was stopped"; return 0 ;;
            failed)    fail "FIS experiment failed"; return 1 ;;
        esac

        local elapsed=$(( $(date +%s) - start_time ))
        if [[ "$elapsed" -ge "$timeout" ]]; then
            fail "FIS experiment timeout after ${timeout}s (status: $status)"
            return 1
        fi

        printf "\r  FIS experiment status: %s (%ss elapsed)" "$status" "$elapsed"
        sleep 10
    done
}

# Emergency stop: push CloudWatch metric to trigger FIS stop condition.
fis_emergency_stop() {
    local experiment_group="$1"
    local region="$2"

    warn "Triggering FIS emergency stop for $experiment_group in $region"
    aws cloudwatch put-metric-data \
        --namespace "Custom/FIS" \
        --metric-name "FISEmergencyStop" \
        --dimensions "ExperimentGroup=$experiment_group" \
        --value 1 \
        --region "$region" 2>/dev/null
}

# ─── Scaling helpers ─────────────────────────────────────────────
get_consumer_pod_count() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"
    kubectl get pods -n "$NAMESPACE" $ctx_flag \
        -l app.kubernetes.io/component=consumer \
        --no-headers 2>/dev/null | wc -l | tr -d ' '
}

get_node_count() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"
    kubectl get nodes $ctx_flag --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# ─── Test result tracking ────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

record_test() {
    local name="$1"
    local result="$2"  # pass or fail

    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$result" == "pass" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        pass "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$name"
    fi
}

print_summary() {
    header "Test Summary"
    echo -e "  Total:  ${BOLD}$TESTS_RUN${RESET}"
    echo -e "  Passed: ${GREEN}$TESTS_PASSED${RESET}"
    echo -e "  Failed: ${RED}$TESTS_FAILED${RESET}"
    echo ""

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        return 1
    fi
    return 0
}
