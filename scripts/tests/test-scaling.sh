#!/usr/bin/env bash
#
# Test: Multi-Region KEDA + Karpenter Scaling
#
# Validates:
#   1. KEDA scales consumer pods based on Kafka consumer lag (amplified by rate limiting)
#   2. Karpenter provisions new nodes when pods cannot be scheduled
#   3. Scale-down works correctly after stress configuration is removed
#   4. Works across both regions (if dual-context available)
#
# Usage: ./scripts/tests/test-scaling.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

# ─── Configuration ────────────────────────────────────────────────
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHART="${REPO_ROOT}/helm/kafka-lab"
VALUES_REGION_A="${VALUES_REGION_A:-${REPO_ROOT}/helm/kafka-lab/env/values-us-east-1.yaml}"
VALUES_REGION_B="${VALUES_REGION_B:-${REPO_ROOT}/helm/kafka-lab/env/values-us-east-2.yaml}"
VALUES_STRESS="${VALUES_STRESS:-${REPO_ROOT}/helm/kafka-lab/env/values-stress.yaml}"

SCALE_UP_TIMEOUT=300      # 5 minutes
SCALE_DOWN_TIMEOUT=600    # 10 minutes (Karpenter consolidation can be slow)
MONITOR_INTERVAL=10

# Track maximums
MAX_CONSUMERS_A=0
MAX_CONSUMERS_B=0
MAX_NODES_A=0
MAX_NODES_B=0
SCALE_UP_TIME_A=0
SCALE_UP_TIME_B=0
SCALE_DOWN_TIME_A=0
SCALE_DOWN_TIME_B=0

# Determine mode: dual-region or single-region
DUAL_REGION=false
if [[ -n "$CONTEXT_A" && -n "$CONTEXT_B" ]]; then
    DUAL_REGION=true
fi

# ─── Step 1: Pre-flight checks ───────────────────────────────────
header "Pre-flight Checks"

# Verify Helm chart exists
if [[ ! -d "$CHART" ]]; then
    die "Helm chart not found at $CHART"
fi
info "Helm chart: $CHART"

# Verify values files exist
if [[ ! -f "$VALUES_REGION_A" ]]; then
    die "Region A values file not found: $VALUES_REGION_A"
fi
info "Region A values: $VALUES_REGION_A"

if [[ ! -f "$VALUES_STRESS" ]]; then
    die "Stress values file not found: $VALUES_STRESS"
fi
info "Stress values: $VALUES_STRESS"

if [[ "$DUAL_REGION" == "true" ]]; then
    info "Mode: dual-region (CONTEXT_A=$CONTEXT_A, CONTEXT_B=$CONTEXT_B)"
    if [[ ! -f "$VALUES_REGION_B" ]]; then
        die "Region B values file not found: $VALUES_REGION_B"
    fi
    info "Region B values: $VALUES_REGION_B"
else
    info "Mode: single-region (using current context)"
fi

# Check KEDA
check_keda() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"
    kubectl get pods -n keda $ctx_flag -l app=keda-operator --no-headers 2>/dev/null | wc -l | tr -d ' '
}

KEDA_A=$(check_keda "$CONTEXT_A")
if [[ "$KEDA_A" -eq 0 ]]; then
    die "KEDA operator not found in Region A"
fi
info "KEDA operator (Region A): running ($KEDA_A pod(s))"

if [[ "$DUAL_REGION" == "true" ]]; then
    KEDA_B=$(check_keda "$CONTEXT_B")
    if [[ "$KEDA_B" -eq 0 ]]; then
        die "KEDA operator not found in Region B"
    fi
    info "KEDA operator (Region B): running ($KEDA_B pod(s))"
fi

# Check Karpenter
check_karpenter() {
    local context="${1:-}"
    local ctx_flag=""
    [[ -n "$context" ]] && ctx_flag="--context=$context"
    local count=0
    for ns in karpenter kube-system; do
        count=$(kubectl get pods -n "$ns" $ctx_flag -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$count" -gt 0 ]]; then
            echo "$count"
            return
        fi
    done
    echo "0"
}

KARPENTER_A=$(check_karpenter "$CONTEXT_A")
if [[ "$KARPENTER_A" -eq 0 ]]; then
    warn "Karpenter not found in Region A — node scaling won't be tested"
else
    info "Karpenter controller (Region A): running"
fi

if [[ "$DUAL_REGION" == "true" ]]; then
    KARPENTER_B=$(check_karpenter "$CONTEXT_B")
    if [[ "$KARPENTER_B" -eq 0 ]]; then
        warn "Karpenter not found in Region B — node scaling won't be tested"
    else
        info "Karpenter controller (Region B): running"
    fi
fi

# ─── Step 2: Record baseline ─────────────────────────────────────
header "Recording Baseline"

BASELINE_CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
BASELINE_NODES_A=$(get_node_count "$CONTEXT_A")
info "Region A ($REGION_A):"
info "  Consumer pods: $BASELINE_CONSUMERS_A"
info "  Nodes: $BASELINE_NODES_A"

if [[ "$DUAL_REGION" == "true" ]]; then
    BASELINE_CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
    BASELINE_NODES_B=$(get_node_count "$CONTEXT_B")
    info "Region B ($REGION_B):"
    info "  Consumer pods: $BASELINE_CONSUMERS_B"
    info "  Nodes: $BASELINE_NODES_B"
else
    BASELINE_CONSUMERS_B=0
    BASELINE_NODES_B=0
fi

MAX_CONSUMERS_A=$BASELINE_CONSUMERS_A
MAX_CONSUMERS_B=$BASELINE_CONSUMERS_B
MAX_NODES_A=$BASELINE_NODES_A
MAX_NODES_B=$BASELINE_NODES_B

# ─── Step 3: Confirm ─────────────────────────────────────────────
echo ""
warn "This will deploy stress configuration via Helm, increasing"
warn "producer throughput and enabling consumer rate limiting to"
warn "trigger KEDA scaling (and potentially Karpenter node scaling)."
echo ""
read -rp "$(echo -e "${YELLOW}Continue with scaling test? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Aborted."
    exit 0
fi

# ─── Step 4: Deploy stress configuration ─────────────────────────
header "Deploying Stress Configuration"

# Region A
if [[ "$DUAL_REGION" == "true" ]]; then
    info "Upgrading Region A: helm upgrade $RELEASE $CHART -f $VALUES_REGION_A -f $VALUES_STRESS --kube-context=$CONTEXT_A"
    helm upgrade "$RELEASE" "$CHART" \
        -f "$VALUES_REGION_A" -f "$VALUES_STRESS" \
        --kube-context="$CONTEXT_A" \
        || die "Helm upgrade failed for Region A"
    info "Stress configuration deployed to Region A"

    info "Upgrading Region B: helm upgrade $RELEASE $CHART -f $VALUES_REGION_B -f $VALUES_STRESS --kube-context=$CONTEXT_B"
    helm upgrade "$RELEASE" "$CHART" \
        -f "$VALUES_REGION_B" -f "$VALUES_STRESS" \
        --kube-context="$CONTEXT_B" \
        || die "Helm upgrade failed for Region B"
    info "Stress configuration deployed to Region B"
else
    info "Upgrading: helm upgrade $RELEASE $CHART -f $VALUES_REGION_A -f $VALUES_STRESS"
    helm upgrade "$RELEASE" "$CHART" \
        -f "$VALUES_REGION_A" -f "$VALUES_STRESS" \
        || die "Helm upgrade failed"
    info "Stress configuration deployed"
fi

STRESS_DEPLOY_TIME=$(date +%s)

# ─── Step 5: Monitor scale-up ────────────────────────────────────
header "Monitoring Scale-Up (up to $((SCALE_UP_TIMEOUT / 60))min)"

info "Tip: Run ./scripts/monitor-scaling.sh in another terminal for detailed view"
echo ""

SCALE_UP_SEEN_A=false
SCALE_UP_SEEN_B=false

for i in $(seq 1 $((SCALE_UP_TIMEOUT / MONITOR_INTERVAL))); do
    ELAPSED=$((i * MONITOR_INTERVAL))

    # Region A metrics
    CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
    NODES_A=$(get_node_count "$CONTEXT_A")

    # Track maximums
    if [[ "$CONSUMERS_A" -gt "$MAX_CONSUMERS_A" ]]; then
        MAX_CONSUMERS_A=$CONSUMERS_A
    fi
    if [[ "$NODES_A" -gt "$MAX_NODES_A" ]]; then
        MAX_NODES_A=$NODES_A
    fi

    # Detect scale-up
    if [[ "$CONSUMERS_A" -gt "$BASELINE_CONSUMERS_A" && "$SCALE_UP_SEEN_A" == "false" ]]; then
        SCALE_UP_SEEN_A=true
        SCALE_UP_TIME_A=$ELAPSED
    fi

    if [[ "$DUAL_REGION" == "true" ]]; then
        CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
        NODES_B=$(get_node_count "$CONTEXT_B")

        if [[ "$CONSUMERS_B" -gt "$MAX_CONSUMERS_B" ]]; then
            MAX_CONSUMERS_B=$CONSUMERS_B
        fi
        if [[ "$NODES_B" -gt "$MAX_NODES_B" ]]; then
            MAX_NODES_B=$NODES_B
        fi
        if [[ "$CONSUMERS_B" -gt "$BASELINE_CONSUMERS_B" && "$SCALE_UP_SEEN_B" == "false" ]]; then
            SCALE_UP_SEEN_B=true
            SCALE_UP_TIME_B=$ELAPSED
        fi

        printf "\r  [%s] A: %s consumers, %s nodes | B: %s consumers, %s nodes | %ss" \
            "$(date +%H:%M:%S)" "$CONSUMERS_A" "$NODES_A" \
            "$CONSUMERS_B" "$NODES_B" "$ELAPSED"
    else
        printf "\r  [%s] Consumers: %s (baseline: %s) | Nodes: %s (baseline: %s) | %ss" \
            "$(date +%H:%M:%S)" "$CONSUMERS_A" "$BASELINE_CONSUMERS_A" \
            "$NODES_A" "$BASELINE_NODES_A" "$ELAPSED"
    fi

    # Both regions scaled (or single region scaled) — give some settling time
    if [[ "$DUAL_REGION" == "true" ]]; then
        if [[ "$SCALE_UP_SEEN_A" == "true" && "$SCALE_UP_SEEN_B" == "true" && "$ELAPSED" -gt 60 ]]; then
            echo ""
            info "Scale-up observed in both regions"
            break
        fi
    else
        if [[ "$SCALE_UP_SEEN_A" == "true" && "$ELAPSED" -gt 60 ]]; then
            echo ""
            info "Scale-up observed"
            break
        fi
    fi

    sleep "$MONITOR_INTERVAL"
done

echo ""

# ─── Step 6: Scale-up results ────────────────────────────────────
header "Scale-Up Phase Complete"

info "Region A ($REGION_A):"
info "  Consumer pods: $BASELINE_CONSUMERS_A -> $MAX_CONSUMERS_A (peak)"
info "  Nodes: $BASELINE_NODES_A -> $MAX_NODES_A (peak)"
if [[ "$SCALE_UP_SEEN_A" == "true" ]]; then
    info "  Scale-up detected at: ${SCALE_UP_TIME_A}s"
fi

if [[ "$DUAL_REGION" == "true" ]]; then
    info "Region B ($REGION_B):"
    info "  Consumer pods: $BASELINE_CONSUMERS_B -> $MAX_CONSUMERS_B (peak)"
    info "  Nodes: $BASELINE_NODES_B -> $MAX_NODES_B (peak)"
    if [[ "$SCALE_UP_SEEN_B" == "true" ]]; then
        info "  Scale-up detected at: ${SCALE_UP_TIME_B}s"
    fi
fi

# ─── Step 7: Prompt before restore ───────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}Restore normal configuration and observe scale-down? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Leaving stress configuration in place. To restore manually:"
    if [[ "$DUAL_REGION" == "true" ]]; then
        info "  helm upgrade $RELEASE $CHART -f $VALUES_REGION_A --kube-context=$CONTEXT_A"
        info "  helm upgrade $RELEASE $CHART -f $VALUES_REGION_B --kube-context=$CONTEXT_B"
    else
        info "  helm upgrade $RELEASE $CHART -f $VALUES_REGION_A"
    fi
    exit 0
fi

# ─── Step 8: Restore normal configuration ─────────────────────────
header "Restoring Normal Configuration"

if [[ "$DUAL_REGION" == "true" ]]; then
    info "Restoring Region A..."
    helm upgrade "$RELEASE" "$CHART" \
        -f "$VALUES_REGION_A" \
        --kube-context="$CONTEXT_A" \
        || die "Helm restore failed for Region A"

    info "Restoring Region B..."
    helm upgrade "$RELEASE" "$CHART" \
        -f "$VALUES_REGION_B" \
        --kube-context="$CONTEXT_B" \
        || die "Helm restore failed for Region B"
else
    info "Restoring: helm upgrade $RELEASE $CHART -f $VALUES_REGION_A"
    helm upgrade "$RELEASE" "$CHART" \
        -f "$VALUES_REGION_A" \
        || die "Helm restore failed"
fi
info "Normal configuration restored"

RESTORE_TIME=$(date +%s)

# ─── Step 9: Monitor scale-down ──────────────────────────────────
header "Monitoring Scale-Down (up to $((SCALE_DOWN_TIMEOUT / 60))min)"

SCALE_DOWN_SEEN_A=false
SCALE_DOWN_SEEN_B=false

for i in $(seq 1 $((SCALE_DOWN_TIMEOUT / MONITOR_INTERVAL))); do
    ELAPSED=$((i * MONITOR_INTERVAL))

    CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
    NODES_A=$(get_node_count "$CONTEXT_A")

    if [[ "$CONSUMERS_A" -le "$BASELINE_CONSUMERS_A" && "$SCALE_DOWN_SEEN_A" == "false" ]]; then
        SCALE_DOWN_SEEN_A=true
        SCALE_DOWN_TIME_A=$ELAPSED
    fi

    if [[ "$DUAL_REGION" == "true" ]]; then
        CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
        NODES_B=$(get_node_count "$CONTEXT_B")

        if [[ "$CONSUMERS_B" -le "$BASELINE_CONSUMERS_B" && "$SCALE_DOWN_SEEN_B" == "false" ]]; then
            SCALE_DOWN_SEEN_B=true
            SCALE_DOWN_TIME_B=$ELAPSED
        fi

        printf "\r  [%s] A: %s consumers, %s nodes | B: %s consumers, %s nodes | %ss" \
            "$(date +%H:%M:%S)" "$CONSUMERS_A" "$NODES_A" \
            "$CONSUMERS_B" "$NODES_B" "$ELAPSED"

        if [[ "$SCALE_DOWN_SEEN_A" == "true" && "$SCALE_DOWN_SEEN_B" == "true" \
              && "$NODES_A" -le "$BASELINE_NODES_A" && "$NODES_B" -le "$BASELINE_NODES_B" ]]; then
            echo ""
            info "Scale-down complete in both regions"
            break
        fi
    else
        printf "\r  [%s] Consumers: %s (target: %s) | Nodes: %s (baseline: %s) | %ss" \
            "$(date +%H:%M:%S)" "$CONSUMERS_A" "$BASELINE_CONSUMERS_A" \
            "$NODES_A" "$BASELINE_NODES_A" "$ELAPSED"

        if [[ "$SCALE_DOWN_SEEN_A" == "true" && "$NODES_A" -le "$BASELINE_NODES_A" ]]; then
            echo ""
            info "Scale-down complete"
            break
        fi
    fi

    sleep "$MONITOR_INTERVAL"
done

echo ""

# ─── Step 10: Record results ─────────────────────────────────────
header "Results"

FINAL_CONSUMERS_A=$(get_consumer_pod_count "$CONTEXT_A")
FINAL_NODES_A=$(get_node_count "$CONTEXT_A")

info "Region A ($REGION_A):"
info "  Consumer pods: $BASELINE_CONSUMERS_A -> $MAX_CONSUMERS_A (peak) -> $FINAL_CONSUMERS_A (final)"
info "  Nodes: $BASELINE_NODES_A -> $MAX_NODES_A (peak) -> $FINAL_NODES_A (final)"
info "  Scale-up time:   ${SCALE_UP_TIME_A}s"
info "  Scale-down time: ${SCALE_DOWN_TIME_A}s"

if [[ "$DUAL_REGION" == "true" ]]; then
    FINAL_CONSUMERS_B=$(get_consumer_pod_count "$CONTEXT_B")
    FINAL_NODES_B=$(get_node_count "$CONTEXT_B")

    info "Region B ($REGION_B):"
    info "  Consumer pods: $BASELINE_CONSUMERS_B -> $MAX_CONSUMERS_B (peak) -> $FINAL_CONSUMERS_B (final)"
    info "  Nodes: $BASELINE_NODES_B -> $MAX_NODES_B (peak) -> $FINAL_NODES_B (final)"
    info "  Scale-up time:   ${SCALE_UP_TIME_B}s"
    info "  Scale-down time: ${SCALE_DOWN_TIME_B}s"
fi

echo ""

# ─── Validate results ────────────────────────────────────────────
# Scale-up: consumer pods should have increased
if [[ "$MAX_CONSUMERS_A" -gt "$BASELINE_CONSUMERS_A" ]]; then
    record_test "KEDA scaled consumers up in Region A ($BASELINE_CONSUMERS_A -> $MAX_CONSUMERS_A)" "pass"
else
    record_test "KEDA did not scale consumers in Region A (stayed at $BASELINE_CONSUMERS_A)" "fail"
fi

if [[ "$DUAL_REGION" == "true" && "$MAX_CONSUMERS_B" -gt "$BASELINE_CONSUMERS_B" ]]; then
    record_test "KEDA scaled consumers up in Region B ($BASELINE_CONSUMERS_B -> $MAX_CONSUMERS_B)" "pass"
elif [[ "$DUAL_REGION" == "true" ]]; then
    record_test "KEDA did not scale consumers in Region B (stayed at $BASELINE_CONSUMERS_B)" "fail"
fi

# Node scaling (only validate if Karpenter is present)
if [[ "$KARPENTER_A" -gt 0 ]]; then
    if [[ "$MAX_NODES_A" -gt "$BASELINE_NODES_A" ]]; then
        record_test "Karpenter provisioned new nodes in Region A ($BASELINE_NODES_A -> $MAX_NODES_A)" "pass"
    else
        record_test "Karpenter did not provision new nodes in Region A (stayed at $BASELINE_NODES_A)" "fail"
    fi
fi

if [[ "$DUAL_REGION" == "true" && "${KARPENTER_B:-0}" -gt 0 ]]; then
    if [[ "$MAX_NODES_B" -gt "$BASELINE_NODES_B" ]]; then
        record_test "Karpenter provisioned new nodes in Region B ($BASELINE_NODES_B -> $MAX_NODES_B)" "pass"
    else
        record_test "Karpenter did not provision new nodes in Region B (stayed at $BASELINE_NODES_B)" "fail"
    fi
fi

# Scale-down: consumers should return to baseline
if [[ "$FINAL_CONSUMERS_A" -le "$BASELINE_CONSUMERS_A" ]]; then
    record_test "KEDA scaled consumers down in Region A ($MAX_CONSUMERS_A -> $FINAL_CONSUMERS_A)" "pass"
else
    record_test "KEDA scale-down incomplete in Region A (at $FINAL_CONSUMERS_A, baseline $BASELINE_CONSUMERS_A)" "fail"
fi

if [[ "$DUAL_REGION" == "true" ]]; then
    if [[ "$FINAL_CONSUMERS_B" -le "$BASELINE_CONSUMERS_B" ]]; then
        record_test "KEDA scaled consumers down in Region B ($MAX_CONSUMERS_B -> $FINAL_CONSUMERS_B)" "pass"
    else
        record_test "KEDA scale-down incomplete in Region B (at $FINAL_CONSUMERS_B, baseline $BASELINE_CONSUMERS_B)" "fail"
    fi
fi

if [[ "$FINAL_NODES_A" -le "$BASELINE_NODES_A" ]]; then
    record_test "Karpenter consolidated nodes in Region A ($MAX_NODES_A -> $FINAL_NODES_A)" "pass"
else
    warn "Nodes still at $FINAL_NODES_A (baseline: $BASELINE_NODES_A) — consolidation may still be in progress"
    record_test "Karpenter consolidation still in progress in Region A ($FINAL_NODES_A nodes, baseline $BASELINE_NODES_A)" "fail"
fi

# ─── Summary ──────────────────────────────────────────────────────
print_summary
