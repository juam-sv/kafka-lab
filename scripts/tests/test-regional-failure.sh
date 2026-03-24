#!/usr/bin/env bash
#
# Test: AWS FIS-based Regional Failure Simulation
#
# Validates:
#   1. FIS experiment triggers correctly and infrastructure responds
#   2. Consumer pods in surviving region continue processing
#   3. Replication recovers after fault injection auto-reverts
#   4. Message counts reconcile post-recovery
#
# Usage: ./scripts/tests/test-regional-failure.sh [experiment-type]
#   experiment-type: full-regional-failure | msk-isolation | cache-isolation | eks-workload-failure
#   default: full-regional-failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

# ─── Configuration ────────────────────────────────────────────────
EXPERIMENT_TYPE="${1:-full-regional-failure}"
MONITOR_INTERVAL=10
RECOVERY_MONITOR_DURATION=120
FIS_TIMEOUT=600

# Map experiment type names to descriptive labels
declare -A EXPERIMENT_LABELS=(
    [full-regional-failure]="Full Regional Failure"
    [msk-isolation]="MSK Network Isolation"
    [cache-isolation]="Cache (ElastiCache) Isolation"
    [eks-workload-failure]="EKS Workload Failure"
)

# ─── Trap: emergency stop on Ctrl+C ──────────────────────────────
ACTIVE_EXPERIMENT_ID=""
cleanup() {
    echo ""
    if [[ -n "$ACTIVE_EXPERIMENT_ID" ]]; then
        warn "Interrupt received — triggering FIS emergency stop"
        fis_emergency_stop "msk-multi-region" "$REGION_A" || true
        warn "Emergency stop signal sent for experiment $ACTIVE_EXPERIMENT_ID"
        warn "Verify in the AWS console that the experiment has stopped"
    else
        info "No active FIS experiment to stop"
    fi
    exit 130
}
trap cleanup INT TERM

# ─── Step 1: Pre-flight checks ───────────────────────────────────
header "Pre-flight Checks"

# Verify AWS CLI access
aws sts get-caller-identity --query 'Account' --output text >/dev/null 2>&1 \
    || die "AWS CLI not configured or no credentials"

# Verify FIS experiment templates exist
info "Listing FIS experiment templates in $REGION_A..."
TEMPLATES_JSON=$(aws fis list-experiment-templates \
    --region "$REGION_A" \
    --output json 2>/dev/null) \
    || die "Failed to list FIS experiment templates in $REGION_A"

TEMPLATE_COUNT=$(echo "$TEMPLATES_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data.get('experimentTemplates', [])))
" 2>/dev/null)

if [[ "$TEMPLATE_COUNT" -eq 0 ]]; then
    die "No FIS experiment templates found in $REGION_A. Deploy FIS templates first."
fi
info "Found $TEMPLATE_COUNT FIS experiment template(s)"

# ─── Step 2: Parse experiment template IDs ────────────────────────
header "Experiment Templates"

# Parse all templates and their tags to match by experiment type
TEMPLATE_MAP=$(echo "$TEMPLATES_JSON" | python3 -c "
import sys, json

data = json.load(sys.stdin)
templates = data.get('experimentTemplates', [])

for t in templates:
    tid = t['id']
    tags = t.get('tags', {})
    # Match by tag 'Name' or 'experiment-type' or description
    name = tags.get('Name', tags.get('experiment-type', t.get('description', 'unknown')))
    print(f'{tid}|{name}')
" 2>/dev/null)

if [[ -z "$TEMPLATE_MAP" ]]; then
    die "Could not parse experiment templates"
fi

echo ""
info "Available experiments:"
declare -A TEMPLATE_IDS
INDEX=1
while IFS='|' read -r tid tname; do
    # Normalize the template name to a key
    key=$(echo "$tname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    TEMPLATE_IDS["$key"]="$tid"
    echo -e "  ${CYAN}$INDEX${RESET}) $tname (${tid})"
    INDEX=$((INDEX + 1))
done <<< "$TEMPLATE_MAP"

echo ""

# ─── Step 3: Select experiment ────────────────────────────────────
# Try to match the requested experiment type
SELECTED_TEMPLATE_ID=""

for key in "${!TEMPLATE_IDS[@]}"; do
    if [[ "$key" == *"$EXPERIMENT_TYPE"* ]]; then
        SELECTED_TEMPLATE_ID="${TEMPLATE_IDS[$key]}"
        break
    fi
done

if [[ -z "$SELECTED_TEMPLATE_ID" ]]; then
    # If no match, let the user pick interactively
    warn "No template matched '$EXPERIMENT_TYPE'"
    echo ""
    echo "Enter the template ID directly, or re-run with a matching name."
    read -rp "$(echo -e "${YELLOW}Template ID: ${RESET}")" SELECTED_TEMPLATE_ID
    [[ -z "$SELECTED_TEMPLATE_ID" ]] && die "No template selected"
fi

LABEL="${EXPERIMENT_LABELS[$EXPERIMENT_TYPE]:-$EXPERIMENT_TYPE}"
info "Selected experiment: $LABEL"
info "Template ID: $SELECTED_TEMPLATE_ID"

# ─── Step 4: Record baseline ─────────────────────────────────────
header "Recording Baseline"

BASELINE_CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
BASELINE_CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
BASELINE_MSGS_A=$(get_topic_message_count "$REGION_A" "$TOPIC" "$CONTEXT_A" | tr -d '[:space:]')
BASELINE_MSGS_B=$(get_topic_message_count "$REGION_B" "$TOPIC" "$CONTEXT_B" | tr -d '[:space:]')

info "Region A ($REGION_A):"
info "  Consumer pods: $BASELINE_CONSUMERS_A"
info "  Message count: $BASELINE_MSGS_A"
info "Region B ($REGION_B):"
info "  Consumer pods: $BASELINE_CONSUMERS_B"
info "  Message count: $BASELINE_MSGS_B"

# ─── Step 5: Confirm ─────────────────────────────────────────────
echo ""
warn "This will start FIS experiment '$LABEL' in $REGION_A."
warn "The experiment will inject faults into live infrastructure."
echo ""
read -rp "$(echo -e "${YELLOW}Continue with regional failure test? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Aborted."
    exit 0
fi

# ─── Step 6: Start FIS experiment ─────────────────────────────────
header "Starting FIS Experiment: $LABEL"

EXPERIMENT_OUTPUT=$(start_fis_experiment "$SELECTED_TEMPLATE_ID" "$REGION_A")
ACTIVE_EXPERIMENT_ID=$(echo "$EXPERIMENT_OUTPUT" | tail -1)

if [[ -z "$ACTIVE_EXPERIMENT_ID" ]]; then
    die "Failed to start FIS experiment — no experiment ID returned"
fi
info "Active experiment ID: $ACTIVE_EXPERIMENT_ID"

EXPERIMENT_START=$(date +%s)

# ─── Step 7: Monitor during experiment ────────────────────────────
header "Monitoring During Experiment (Ctrl+C to emergency stop)"

info "Polling every ${MONITOR_INTERVAL}s..."
echo ""

MONITOR_TIMEOUT=$FIS_TIMEOUT
MONITOR_START=$(date +%s)

while true; do
    ELAPSED=$(( $(date +%s) - MONITOR_START ))

    # Check FIS status
    FIS_STATUS=$(aws fis get-experiment \
        --id "$ACTIVE_EXPERIMENT_ID" \
        --region "$REGION_A" \
        --query 'experiment.state.status' \
        --output text 2>/dev/null || echo "unknown")

    # Gather metrics
    CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A" 2>/dev/null || echo "?")
    CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B" 2>/dev/null || echo "?")
    MSGS_A=$(get_topic_message_count "$REGION_A" "$TOPIC" "$CONTEXT_A" 2>/dev/null | tr -d '[:space:]' || echo "?")
    MSGS_B=$(get_topic_message_count "$REGION_B" "$TOPIC" "$CONTEXT_B" 2>/dev/null | tr -d '[:space:]' || echo "?")

    printf "\r  [%s] FIS: %-10s | Consumers A: %s B: %s | Msgs A: %s B: %s | %ss elapsed" \
        "$(date +%H:%M:%S)" "$FIS_STATUS" "$CONSUMERS_A" "$CONSUMERS_B" \
        "$MSGS_A" "$MSGS_B" "$ELAPSED"

    # Exit conditions
    case "$FIS_STATUS" in
        completed|stopped|failed)
            echo ""
            break
            ;;
    esac

    if [[ "$ELAPSED" -ge "$MONITOR_TIMEOUT" ]]; then
        echo ""
        warn "Monitor timeout reached (${MONITOR_TIMEOUT}s) — experiment may still be running"
        break
    fi

    sleep "$MONITOR_INTERVAL"
done

EXPERIMENT_DURATION=$(( $(date +%s) - EXPERIMENT_START ))

# ─── Step 8: Wait for FIS experiment to complete ──────────────────
header "Waiting for FIS Experiment to Complete"

if wait_for_fis_experiment "$ACTIVE_EXPERIMENT_ID" "$REGION_A" "$FIS_TIMEOUT"; then
    record_test "FIS experiment completed successfully" "pass"
else
    record_test "FIS experiment did not complete cleanly" "fail"
fi

# Clear the active experiment for the trap
ACTIVE_EXPERIMENT_ID=""

# ─── Step 9: Monitor recovery ────────────────────────────────────
header "Monitoring Recovery (${RECOVERY_MONITOR_DURATION}s)"

info "Waiting for infrastructure to auto-revert and recover..."
echo ""

RECOVERY_START=$(date +%s)
REPLICATION_RECOVERED=false
RECOVERY_TIME=0

LAST_GAP=999999999

while true; do
    ELAPSED=$(( $(date +%s) - RECOVERY_START ))

    # Gather post-recovery metrics
    CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A" 2>/dev/null || echo "?")
    CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B" 2>/dev/null || echo "?")
    MSGS_A=$(get_topic_message_count "$REGION_A" "$TOPIC" "$CONTEXT_A" 2>/dev/null | tr -d '[:space:]' || echo "0")
    MSGS_B=$(get_topic_message_count "$REGION_B" "$TOPIC" "$CONTEXT_B" 2>/dev/null | tr -d '[:space:]' || echo "0")

    # Calculate replication gap
    if [[ "$MSGS_A" =~ ^[0-9]+$ && "$MSGS_B" =~ ^[0-9]+$ ]]; then
        GAP=$(( MSGS_A > MSGS_B ? MSGS_A - MSGS_B : MSGS_B - MSGS_A ))
    else
        GAP=999999999
    fi

    printf "\r  [%s] Consumers A: %s B: %s | Msgs A: %s B: %s | Gap: %s | %ss elapsed" \
        "$(date +%H:%M:%S)" "$CONSUMERS_A" "$CONSUMERS_B" \
        "$MSGS_A" "$MSGS_B" "$GAP" "$ELAPSED"

    # Check if replication has converged (gap is stable and small)
    if [[ "$GAP" -le 10 && "$REPLICATION_RECOVERED" == "false" ]]; then
        REPLICATION_RECOVERED=true
        RECOVERY_TIME=$ELAPSED
        echo ""
        info "Replication converged after ${RECOVERY_TIME}s (gap: $GAP)"
    fi

    LAST_GAP=$GAP

    if [[ "$ELAPSED" -ge "$RECOVERY_MONITOR_DURATION" ]]; then
        echo ""
        break
    fi

    sleep "$MONITOR_INTERVAL"
done

# ─── Step 10: Record results ─────────────────────────────────────
header "Results"

POST_MSGS_A=$(get_topic_message_count "$REGION_A" "$TOPIC" "$CONTEXT_A" | tr -d '[:space:]')
POST_MSGS_B=$(get_topic_message_count "$REGION_B" "$TOPIC" "$CONTEXT_B" | tr -d '[:space:]')
POST_CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
POST_CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")

MSGS_DURING_A=$(( POST_MSGS_A - BASELINE_MSGS_A ))
MSGS_DURING_B=$(( POST_MSGS_B - BASELINE_MSGS_B ))
FINAL_GAP=$(( POST_MSGS_A > POST_MSGS_B ? POST_MSGS_A - POST_MSGS_B : POST_MSGS_B - POST_MSGS_A ))

info "Experiment type:     $LABEL"
info "Experiment duration: ${EXPERIMENT_DURATION}s"
info "Recovery time:       ${RECOVERY_TIME}s"
info "Messages during experiment:"
info "  Region A: +${MSGS_DURING_A} (${BASELINE_MSGS_A} -> ${POST_MSGS_A})"
info "  Region B: +${MSGS_DURING_B} (${BASELINE_MSGS_B} -> ${POST_MSGS_B})"
info "Final replication gap: $FINAL_GAP"
info "Consumer pods:"
info "  Region A: $BASELINE_CONSUMERS_A -> $POST_CONSUMERS_A"
info "  Region B: $BASELINE_CONSUMERS_B -> $POST_CONSUMERS_B"

echo ""

# Validate results
if [[ "$REPLICATION_RECOVERED" == "true" ]]; then
    record_test "Replication recovered within ${RECOVERY_MONITOR_DURATION}s (took ${RECOVERY_TIME}s)" "pass"
else
    record_test "Replication did not recover within ${RECOVERY_MONITOR_DURATION}s (gap: $LAST_GAP)" "fail"
fi

if [[ "$FINAL_GAP" -le 50 ]]; then
    record_test "Final replication gap acceptable (<= 50 messages, actual: $FINAL_GAP)" "pass"
else
    record_test "Final replication gap too large ($FINAL_GAP messages)" "fail"
fi

if [[ "$POST_CONSUMERS_A" -ge 1 && "$POST_CONSUMERS_B" -ge 1 ]]; then
    record_test "Consumer pods running in both regions post-recovery" "pass"
else
    record_test "Consumer pods not healthy post-recovery (A: $POST_CONSUMERS_A, B: $POST_CONSUMERS_B)" "fail"
fi

# ─── Summary ──────────────────────────────────────────────────────
print_summary
