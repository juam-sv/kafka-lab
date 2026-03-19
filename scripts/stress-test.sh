#!/usr/bin/env bash
#
# Stress Test: KEDA Consumer Scaling + Karpenter Node Scaling
#
# Validates:
#   1. KEDA scales consumer pods based on Kafka consumer lag
#   2. Karpenter provisions new nodes when pods can't be scheduled
#   3. Scale-down works correctly after load is removed
#
# Usage: ./scripts/stress-test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="kafka-lab"
CHART="${REPO_ROOT}/helm/kafka-lab"
VALUES_REGION="${REPO_ROOT}/helm/kafka-lab/env/values-us-east-1.yaml"
VALUES_STRESS="${REPO_ROOT}/helm/kafka-lab/env/values-stress.yaml"
TOPIC="financial.transactions"
NAMESPACE="default"
TARGET_PARTITIONS=10

# ─── Colors ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo -e "${CYAN}  $*${RESET}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"
}

info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET} $*"; exit 1; }

# ─── Step 1: Pre-flight checks ──────────────────────────────────
header "Pre-flight Checks"

CONTEXT=$(kubectl config current-context 2>/dev/null) || fail "kubectl not configured"
info "Kubectl context: $CONTEXT"

KEDA_PODS=$(kubectl get pods -n keda -l app=keda-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$KEDA_PODS" -eq 0 ]]; then
    fail "KEDA operator not found in namespace 'keda'"
fi
info "KEDA operator: running ($KEDA_PODS pod(s))"

KARPENTER_PODS=""
for ns in karpenter kube-system; do
    KARPENTER_PODS=$(kubectl get pods -n "$ns" -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | grep -c . || true)
    if [[ "$KARPENTER_PODS" -gt 0 ]]; then break; fi
done
if [[ "$KARPENTER_PODS" -eq 0 ]]; then
    warn "Karpenter controller not found — node scaling won't be tested"
else
    info "Karpenter controller: running"
fi

INITIAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
INITIAL_CONSUMERS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=consumer --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "Baseline nodes: $INITIAL_NODES"
info "Baseline consumer pods: $INITIAL_CONSUMERS"

echo ""
read -rp "$(echo -e "${YELLOW}Continue with stress test? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Aborted."
    exit 0
fi

# ─── Step 2: Increase topic partitions ──────────────────────────
header "Increasing Topic Partitions to $TARGET_PARTITIONS"

BROKERS=$(kubectl get configmap -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].data.KAFKA_BROKER}' 2>/dev/null || echo "")
PRODUCER_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=producer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$BROKERS" || -z "$PRODUCER_POD" ]]; then
    warn "No producer pod or configmap found — skipping partition increase"
    warn "You may need to increase partitions manually"
else
    info "Checking current partition count via $PRODUCER_POD"

    CURRENT_PARTITIONS=$(kubectl exec -n "$NAMESPACE" "$PRODUCER_POD" -- python -c "
import os
from confluent_kafka import Producer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', 'us-east-1')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
p = Producer({'bootstrap.servers': os.environ['KAFKA_BROKER'], 'security.protocol': 'SASL_SSL', 'sasl.mechanism': 'OAUTHBEARER', 'oauth_cb': oauth_cb})
md = p.list_topics(topic='$TOPIC', timeout=10)
print(len(md.topics['$TOPIC'].partitions))
" 2>/dev/null || echo "0")

    if [[ "$CURRENT_PARTITIONS" -ge "$TARGET_PARTITIONS" ]]; then
        info "Topic already has $CURRENT_PARTITIONS partitions (>= $TARGET_PARTITIONS), skipping"
    else
        info "Current partitions: $CURRENT_PARTITIONS → increasing to $TARGET_PARTITIONS"

        # Get MSK cluster ARN and use AWS CLI (no heavy Python admin client needed)
        MSK_ARN=$(aws kafka list-clusters-v2 --region us-east-1 --query "ClusterInfoList[?ClusterName=='ic-poc-use1'].ClusterArn | [0]" --output text 2>/dev/null || echo "")

        if [[ -n "$MSK_ARN" && "$MSK_ARN" != "None" ]]; then
            info "Using AWS CLI to update partitions (cluster: $MSK_ARN)"
            aws kafka update-topic --region us-east-1 \
                --cluster-arn "$MSK_ARN" \
                --topic-name "$TOPIC" \
                --partitions "$TARGET_PARTITIONS" 2>&1 || warn "AWS CLI partition increase failed"
        else
            warn "Could not find MSK cluster ARN — falling back to Kafka admin client"
            # Fallback: use an ephemeral pod with more memory
            PRODUCER_IMAGE=$(kubectl get pod -n "$NAMESPACE" "$PRODUCER_POD" -o jsonpath='{.spec.containers[0].image}')
            PRODUCER_SA=$(kubectl get pod -n "$NAMESPACE" "$PRODUCER_POD" -o jsonpath='{.spec.serviceAccountName}')

            kubectl run stress-partition-alter \
                -n "$NAMESPACE" \
                --image="$PRODUCER_IMAGE" \
                --restart=Never \
                --rm -i \
                --serviceaccount="$PRODUCER_SA" \
                --override-type=strategic \
                --overrides='{"spec":{"containers":[{"name":"stress-partition-alter","resources":{"requests":{"memory":"1Gi"},"limits":{"memory":"1Gi"}}}]}}' \
                --env="KAFKA_BROKER=$BROKERS" \
                --env="AWS_REGION=us-east-1" \
                --command -- python -c "
import os
from confluent_kafka.admin import AdminClient, NewPartitions
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
region = os.getenv('AWS_REGION', 'us-east-1')
def oauth_cb(c):
    t, e = MSKAuthTokenProvider.generate_auth_token(region)
    return t, e / 1000
a = AdminClient({'bootstrap.servers': os.environ['KAFKA_BROKER'], 'security.protocol': 'SASL_SSL', 'sasl.mechanism': 'OAUTHBEARER', 'oauth_cb': oauth_cb})
fs = a.create_partitions([NewPartitions('$TOPIC', $TARGET_PARTITIONS)])
for t, f in fs.items(): f.result()
print('Done')
" 2>&1 || warn "Partition increase failed — may need manual intervention"
        fi
    fi
fi

# ─── Step 3: Deploy stress configuration ────────────────────────
header "Deploying Stress Configuration"

info "Running: helm upgrade $RELEASE $CHART -f $VALUES_REGION -f $VALUES_STRESS"
helm upgrade "$RELEASE" "$CHART" -f "$VALUES_REGION" -f "$VALUES_STRESS" || fail "Helm upgrade failed"
info "Stress configuration deployed"

# ─── Step 4: Observe scale-up ───────────────────────────────────
header "Monitoring Scale-Up (Ctrl+C to skip to restore)"

info "Tip: Run ./scripts/monitor-scaling.sh in another terminal for detailed view"
echo ""

SCALE_UP_OBSERVED=false

for i in $(seq 1 60); do
    CONSUMERS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=consumer --no-headers 2>/dev/null || echo "")
    if [[ -z "$CONSUMERS" ]]; then
        CONSUMER_RUNNING=0; CONSUMER_PENDING=0; CONSUMER_TOTAL=0
    else
        CONSUMER_RUNNING=$(echo "$CONSUMERS" | grep -c "Running" || true)
        CONSUMER_PENDING=$(echo "$CONSUMERS" | grep -c "Pending" || true)
        CONSUMER_TOTAL=$(echo "$CONSUMERS" | wc -l | tr -d ' ')
    fi
    NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    PRODUCERS_RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=producer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

    printf "\r  [%s] Consumers: %s/%s (Pending: %s) | Nodes: %s (started: %s) | Producers: %s/8" \
        "$(date +%H:%M:%S)" "$CONSUMER_RUNNING" "$CONSUMER_TOTAL" "$CONSUMER_PENDING" "$NODES" "$INITIAL_NODES" "$PRODUCERS_RUNNING"

    if [[ "$CONSUMER_TOTAL" -gt "$INITIAL_CONSUMERS" && "$CONSUMER_RUNNING" -eq "$CONSUMER_TOTAL" ]]; then
        SCALE_UP_OBSERVED=true
    fi

    if [[ "$SCALE_UP_OBSERVED" == "true" && $i -gt 12 ]]; then
        echo ""
        echo ""
        info "Scale-up observed: $CONSUMER_TOTAL consumer(s) running, $NODES node(s)"
        break
    fi

    sleep 10
done

# ─── Step 5: Prompt before restore ──────────────────────────────
echo ""
header "Scale-Up Phase Complete"
info "Consumer pods: $CONSUMER_TOTAL (started from $INITIAL_CONSUMERS)"
info "Nodes: $NODES (started from $INITIAL_NODES)"
echo ""
read -rp "$(echo -e "${YELLOW}Restore normal configuration and observe scale-down? (y/N) ${RESET}")" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Leaving stress configuration in place. To restore manually:"
    info "  helm upgrade $RELEASE $CHART -f $VALUES_REGION"
    exit 0
fi

# ─── Step 6: Restore normal configuration ───────────────────────
header "Restoring Normal Configuration"

info "Running: helm upgrade $RELEASE $CHART -f $VALUES_REGION"
helm upgrade "$RELEASE" "$CHART" -f "$VALUES_REGION" || fail "Helm restore failed"
info "Normal configuration restored"

# ─── Step 7: Observe scale-down ─────────────────────────────────
header "Monitoring Scale-Down"

for i in $(seq 1 60); do
    CONSUMERS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=consumer --no-headers 2>/dev/null || echo "")
    if [[ -z "$CONSUMERS" ]]; then
        CONSUMER_TOTAL=0
    else
        CONSUMER_TOTAL=$(echo "$CONSUMERS" | wc -l | tr -d ' ')
    fi
    NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')

    printf "\r  [%s] Consumers: %s (target: 1) | Nodes: %s (started: %s)" \
        "$(date +%H:%M:%S)" "$CONSUMER_TOTAL" "$NODES" "$INITIAL_NODES"

    if [[ "$CONSUMER_TOTAL" -le 1 && "$NODES" -le "$INITIAL_NODES" ]]; then
        echo ""
        echo ""
        info "Scale-down complete"
        break
    fi

    sleep 10
done

# ─── Summary ────────────────────────────────────────────────────
header "Stress Test Complete"

FINAL_CONSUMERS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=consumer --no-headers 2>/dev/null | wc -l | tr -d ' ')
FINAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')

info "Final consumer pods: $FINAL_CONSUMERS"
info "Final nodes: $FINAL_NODES"

if [[ "$FINAL_CONSUMERS" -le 1 ]]; then
    echo -e "${GREEN}  [PASS]${RESET} KEDA scaled consumers back to minReplicas"
else
    echo -e "${YELLOW}  [WAIT]${RESET} Consumers still at $FINAL_CONSUMERS — KEDA cooldown may still be in progress"
fi

if [[ "$FINAL_NODES" -le "$INITIAL_NODES" ]]; then
    echo -e "${GREEN}  [PASS]${RESET} Karpenter consolidated nodes back to baseline"
else
    echo -e "${YELLOW}  [WAIT]${RESET} Nodes still at $FINAL_NODES (baseline: $INITIAL_NODES) — consolidation may still be in progress"
fi
