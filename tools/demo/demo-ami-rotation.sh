#!/usr/bin/env bash
# Helper to demonstrate a Karpenter-driven AMI rotation with k6 evidence.
# Usage:  ./demo-ami-rotation.sh <env-base-url>
#
# What it does:
#   1. Resolves current vs latest Bottlerocket AMI from SSM
#   2. Fires up k6 in the background against the env
#   3. Reminds you to merge the AMI bump PR + run terraform apply
#   4. Streams nodes/pods status while Karpenter rotates
#   5. Tails k6 final summary

set -euo pipefail

BASE_URL="${1:?usage: $0 <https://app.<env>.<domain>>}"
DURATION="${DURATION:-15m}"
EKS_VERSION="${EKS_VERSION:-1.30}"

echo "→ Looking up Bottlerocket AMIs"
LATEST=$(aws ssm get-parameter \
  --name "/aws/service/bottlerocket/aws-k8s-${EKS_VERSION}/x86_64/latest/image_id" \
  --query Parameter.Value --output text)
echo "  latest in SSM:  $LATEST"

if command -v terraform >/dev/null && [ -f "infra/terraform/envs/nonprod/.terraform.lock.hcl" ]; then
  CURRENT=$(terraform -chdir=infra/terraform/envs/nonprod output -raw current_bottlerocket_ami_id 2>/dev/null || echo "?")
  echo "  current pinned: $CURRENT"
fi

echo
echo "→ Starting k6 ($DURATION)"
k6 run -e BASE_URL="$BASE_URL" -e DURATION="$DURATION" \
  tools/load-test/k6-zero-downtime.js > /tmp/k6.out 2>&1 &
K6_PID=$!
echo "  k6 PID: $K6_PID  (logs: /tmp/k6.out)"

cat <<'TXT'

→ Now in another terminal, perform the AMI bump:
    cd infra/terraform/envs/nonprod
    terraform plan
    terraform apply
  (the SSM data source resolves to the new image_id; EC2NodeClass diff
   triggers Karpenter drift)

→ Watching nodes:
TXT

kubectl get nodes -w &
WATCH_PID=$!

trap 'kill $WATCH_PID $K6_PID 2>/dev/null || true' EXIT

wait $K6_PID || true
echo
echo "→ k6 summary:"
tail -n 80 /tmp/k6.out
