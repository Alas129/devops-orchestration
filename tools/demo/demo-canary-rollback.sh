#!/usr/bin/env bash
# Demonstrate Argo Rollouts canary auto-rollback: deploy a deliberately
# broken image, watch the AnalysisTemplate fail, watch Argo Rollouts abort
# the canary and pin traffic back to the stable ReplicaSet.
#
# Usage:
#   ./demo-canary-rollback.sh <namespace> <rollout-name> <broken-image-tag>
#
# Example:
#   ./demo-canary-rollback.sh dev auth-svc git-DEADBEEFFFFF
#
# What it does:
#   1. Patches the rollout to use the broken image tag (simulating a buggy
#      build that returns 500s)
#   2. Tails the rollout state every 5s
#   3. After abort, prints the AnalysisRun result and current weight
#
# Prereqs:
#   - kubectl + kubectl-argo-rollouts plugin
#   - Already kubectl-authed against the target cluster
#   - The "broken" image must exist in ECR and start failing on requests
#     (one way: an image whose /healthz returns 200 but /api/* returns 500)
#
# The "real" prod canary criteria are defined in
# charts/<svc>/templates/analysistemplate.yaml — success rate >= 99% and
# p95 latency <= 500ms over 2 min. Falling below either triggers abort.

set -euo pipefail

NS="${1:?usage: $0 <namespace> <rollout> <bad-image-tag>}"
ROLLOUT="${2:?usage: $0 <namespace> <rollout> <bad-image-tag>}"
BAD_TAG="${3:?usage: $0 <namespace> <rollout> <bad-image-tag>}"

CONTAINER_NAME="app"
[ "$ROLLOUT" = "frontend" ] && CONTAINER_NAME="web"

REPO=$(kubectl -n "$NS" get rollout "$ROLLOUT" -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER_NAME}')].image}" | cut -d: -f1 | cut -d@ -f1)
echo "→ Current image base: $REPO"
echo "→ Setting canary tag to: $BAD_TAG"

kubectl argo rollouts set image "$ROLLOUT" -n "$NS" \
  "${CONTAINER_NAME}=${REPO}:${BAD_TAG}"

echo
echo "→ Tailing rollout state (Ctrl-C to stop)"
echo "  Expected sequence over the next 2-5 min:"
echo "  - Step 1: setWeight 10, canary RS spins up"
echo "  - AnalysisRun starts watching prom metrics"
echo "  - Bad image → 5xx → success rate < 99% → AnalysisRun = Failed"
echo "  - Rollout phase: Degraded -> automatic abort"
echo "  - Traffic returns to stable RS, canary RS scaled to 0"
echo

kubectl argo rollouts get rollout "$ROLLOUT" -n "$NS" --watch

# After Ctrl-C, summarise
echo
echo "─── post-mortem ───"
kubectl argo rollouts status "$ROLLOUT" -n "$NS" --watch=false || true
echo
echo "→ AnalysisRun result:"
kubectl get analysisrun -n "$NS" -l rollout-name="$ROLLOUT" --sort-by=.metadata.creationTimestamp -o wide | tail -3
echo
echo "→ To clean up (re-deploy a known-good tag):"
echo "    kubectl argo rollouts set image $ROLLOUT -n $NS ${CONTAINER_NAME}=${REPO}:<good-tag>"
echo "    kubectl argo rollouts promote $ROLLOUT -n $NS"
