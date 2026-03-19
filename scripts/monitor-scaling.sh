#!/usr/bin/env bash
#
# Live monitoring dashboard for KEDA/Karpenter stress test.
# Run in a separate terminal alongside stress-test.sh.
#
# Usage: ./scripts/monitor-scaling.sh

set -euo pipefail

NAMESPACE="default"
RELEASE="kafka-lab"
CONSUMER_GROUP="finance-group"
TOPIC="financial.transactions"
REFRESH=5

# ─── Colors ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

# Capture starting node count
INITIAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')

while true; do
    clear

    # ── Header ──
    echo -e "${CYAN}${BOLD}── Stress Test Monitor ──────────────────────────────${RESET}"
    echo -e "${DIM}  $(date +"%Y-%m-%d %H:%M:%S")  (refresh: ${REFRESH}s)${RESET}"
    echo ""

    # ── KEDA ScaledObject ──
    SO_JSON=$(kubectl get scaledobject -n "$NAMESPACE" -o json 2>/dev/null || echo "")
    if [[ -n "$SO_JSON" ]]; then
        SO_NAME=$(echo "$SO_JSON" | python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0]['metadata']['name'] if items else 'N/A')" 2>/dev/null || echo "N/A")
        SO_ACTIVE=$(echo "$SO_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if items:
    conditions = items[0].get('status', {}).get('conditions', [])
    for c in conditions:
        if c.get('type') == 'Active':
            print(c.get('status', 'Unknown'))
            break
    else:
        print('Unknown')
else:
    print('N/A')
" 2>/dev/null || echo "Unknown")
        SO_DESIRED=$(echo "$SO_JSON" | python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0].get('status',{}).get('desiredReplicas','?') if items else '?')" 2>/dev/null || echo "?")

        if [[ "$SO_ACTIVE" == "True" ]]; then
            ACTIVE_COLOR="$GREEN"
        else
            ACTIVE_COLOR="$YELLOW"
        fi
        echo -e "  ${BOLD}KEDA ScaledObject:${RESET}  ${ACTIVE_COLOR}${SO_ACTIVE}${RESET} | Desired: ${SO_DESIRED} | Name: ${DIM}${SO_NAME}${RESET}"
    else
        echo -e "  ${BOLD}KEDA ScaledObject:${RESET}  ${RED}not found${RESET}"
    fi

    # ── Consumer Pods ──
    CONSUMER_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=consumer --no-headers 2>/dev/null || echo "")
    if [[ -z "$CONSUMER_PODS" ]]; then
        CONSUMER_RUNNING=0; CONSUMER_PENDING=0; CONSUMER_TOTAL=0
    else
        CONSUMER_RUNNING=$(echo "$CONSUMER_PODS" | grep -c "Running" || true)
        CONSUMER_PENDING=$(echo "$CONSUMER_PODS" | grep -c "Pending" || true)
        CONSUMER_TOTAL=$(echo "$CONSUMER_PODS" | wc -l | tr -d ' ')
    fi

    PENDING_INFO=""
    if [[ "$CONSUMER_PENDING" -gt 0 ]]; then
        PENDING_INFO=" (${RED}${CONSUMER_PENDING} Pending${RESET})"
    fi
    echo -e "  ${BOLD}Consumer Pods:${RESET}      ${GREEN}${CONSUMER_RUNNING}${RESET}/${CONSUMER_TOTAL} Running${PENDING_INFO}"

    # ── Producer Pods ──
    PRODUCER_RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=producer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    PRODUCER_TOTAL=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=producer --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${BOLD}Producer Pods:${RESET}      ${GREEN}${PRODUCER_RUNNING}${RESET}/${PRODUCER_TOTAL} Running"

    # ── Nodes ──
    CURRENT_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    NODE_DIFF=$((CURRENT_NODES - INITIAL_NODES))
    DIFF_STR=""
    if [[ $NODE_DIFF -gt 0 ]]; then
        DIFF_STR=" (${GREEN}+${NODE_DIFF}${RESET})"
    elif [[ $NODE_DIFF -lt 0 ]]; then
        DIFF_STR=" (${RED}${NODE_DIFF}${RESET})"
    fi
    echo -e "  ${BOLD}Nodes:${RESET}              ${CURRENT_NODES}${DIFF_STR} (started: ${INITIAL_NODES})"

    # ── Consumer Lag ──
    echo ""
    echo -e "  ${BOLD}Consumer Lag:${RESET}"

    CONSUMER_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=consumer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    BROKERS=$(kubectl get configmap -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].data.KAFKA_BROKER}' 2>/dev/null || echo "")

    if [[ -n "$CONSUMER_POD" && -n "$BROKERS" ]]; then
        LAG_OUTPUT=$(kubectl exec -n "$NAMESPACE" "$CONSUMER_POD" -- python3 -c "
from confluent_kafka import Consumer
from confluent_kafka import TopicPartition

import os
conf = {'bootstrap.servers': '$BROKERS', 'group.id': '$CONSUMER_GROUP'}
use_msk = os.getenv('KAFKA_USE_MSK', 'false').lower() == 'true'
if use_msk:
    from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
    region = os.getenv('AWS_REGION', 'us-east-1')
    def oauth_cb(config):
        token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(region)
        return token, expiry_ms / 1000
    conf.update({
        'security.protocol': 'SASL_SSL',
        'sasl.mechanism': 'OAUTHBEARER',
        'oauth_cb': oauth_cb,
    })

try:
    c = Consumer(conf)
    topics = c.list_topics(topic='$TOPIC', timeout=5)
    partitions = topics.topics['$TOPIC'].partitions
    lags = {}
    for pid in sorted(partitions.keys()):
        tp = TopicPartition('$TOPIC', pid)
        committed = c.committed([tp], timeout=5)
        lo, hi = c.get_watermark_offsets(tp, timeout=5)
        committed_offset = committed[0].offset if committed[0].offset >= 0 else 0
        lag = hi - committed_offset
        lags[pid] = lag
    parts = [f'P{k}:{v}' for k,v in lags.items()]
    total = sum(lags.values())
    print(f'    {\" | \".join(parts)}')
    print(f'    Total lag: {total}')
    c.close()
except Exception as e:
    print(f'    Error: {e}')
" 2>&1 || echo "    Could not retrieve lag")
        echo "$LAG_OUTPUT"
    else
        echo -e "    ${DIM}(no consumer pod or brokers available)${RESET}"
    fi

    # ── Pod details ──
    echo ""
    echo -e "  ${BOLD}Consumer Pod Status:${RESET}"
    if [[ -n "$CONSUMER_PODS" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            POD_NAME=$(echo "$line" | awk '{print $1}')
            POD_STATUS=$(echo "$line" | awk '{print $3}')
            POD_NODE=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unscheduled")
            if [[ "$POD_STATUS" == "Running" ]]; then
                echo -e "    ${GREEN}●${RESET} ${POD_NAME} → ${DIM}${POD_NODE}${RESET}"
            elif [[ "$POD_STATUS" == "Pending" ]]; then
                echo -e "    ${YELLOW}●${RESET} ${POD_NAME} → ${YELLOW}pending scheduling${RESET}"
            else
                echo -e "    ${RED}●${RESET} ${POD_NAME} → ${POD_STATUS}"
            fi
        done <<< "$CONSUMER_PODS"
    else
        echo -e "    ${DIM}(none)${RESET}"
    fi

    echo ""
    echo -e "${CYAN}${BOLD}────────────────────────────────────────────────────────${RESET}"

    sleep "$REFRESH"
done
