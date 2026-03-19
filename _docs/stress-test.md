# Stress Test — KEDA Consumer Scaling + Karpenter Node Scaling

Validates that KEDA scales consumer pods based on Kafka consumer lag and that Karpenter provisions new nodes when pods can't be scheduled.

## Prerequisites

- `kubectl` configured for the EKS cluster (`ic-poc-eks`)
- KEDA operator installed (namespace `keda`)
- Karpenter controller installed (optional — node scaling won't be tested without it)
- Helm chart already deployed with `values-us-east-1.yaml`

## What It Does

| Phase | Action |
|-------|--------|
| Pre-flight | Verifies kubectl context, KEDA, Karpenter, captures baseline node/pod counts |
| Partitions | Increases `financial.transactions` from 3 → 10 partitions (matches KEDA maxReplicas) |
| Stress deploy | Applies `values-stress.yaml` overlay: 8 producers × 1000 msg/s, inflated consumer CPU requests |
| Scale-up | Polls every 10s showing consumer replicas, pending pods, and node count |
| Restore | Removes stress overlay, reverts to normal `values-us-east-1.yaml` config |
| Scale-down | Monitors consumers scaling back to 1 and excess nodes being consolidated |

## Usage

```bash
# Terminal 1 — run the stress test
./scripts/stress-test.sh

# Terminal 2 (optional) — live monitoring dashboard
./scripts/monitor-scaling.sh
```

The stress test is interactive — it prompts before deploying and before restoring.

## Stress Parameters

Defined in `helm/kafka-lab/env/values-stress.yaml`:

| Parameter | Normal | Stress | Why |
|-----------|--------|--------|-----|
| Producer replicas | 4 | 8 | Higher message throughput |
| Messages/sec per producer | 400 | 1000 | Generates consumer lag quickly |
| Consumer CPU request | 100m | 500m | ~6 consumers fill a node → forces Karpenter to add nodes |
| KEDA lagThreshold | 10 | 5 | More aggressive scaling trigger |
| KEDA cooldownPeriod | 60s | 30s | Faster scale-down for quicker test cycles |

## What to Look For

1. **KEDA scale-up** — consumer pods increase from 1 → N within ~30-60s
2. **Karpenter provisioning** — new nodes appear when consumer pods are Pending (~60-90s)
3. **Lag recovery** — consumer lag decreases as more consumers come online
4. **KEDA scale-down** — after restoring normal rate, consumers return to 1 (after cooldown)
5. **Karpenter consolidation** — excess nodes terminated after pods are removed

## Restoring Manually

If the script is interrupted during the stress phase:

```bash
helm upgrade kafka-lab helm/kafka-lab/ -f helm/kafka-lab/env/values-us-east-1.yaml
```
