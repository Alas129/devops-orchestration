#!/usr/bin/env bash
# After `terraform apply` on infra/terraform/envs/prod, verify that the
# prod overlays in gitops/overlays/prod/ are aligned with the real AWS
# resources, AND set up the Cloudflare CNAME that lets the overlay
# reference a stable DNS name for the RDS endpoint.
#
# Most of the prod overlay is now PRE-FILLED with predictable values:
#   - IRSA role ARNs: `usf-devops-prod-{svc}` (deterministic from TF)
#   - ALB logs bucket: `usf-devops-alb-logs-prod-{account}`
#   - ACM cert: empty → AWS Load Balancer Controller auto-discovers
#                       (the ACM cert created by module.acm_prod has
#                       SANs covering app/api.prod.calmloop.space)
#
# The only thing still requiring a runtime step is the RDS endpoint
# CNAME — AWS generates a random subdomain for RDS hostnames that we
# can't predict. We set up `prod-db.calmloop.space` to alias whatever
# AWS gave us, and the overlay references the CNAME.
#
# Usage:
#   tools/populate-prod-from-tf.sh                # apply changes
#   tools/populate-prod-from-tf.sh --dry-run      # show what would change
#   tools/populate-prod-from-tf.sh --check        # exit non-zero on drift
set -euo pipefail

MODE=${1:-}
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROD_TF_DIR="$REPO_ROOT/infra/terraform/envs/prod"

if ! command -v jq >/dev/null; then echo "error: jq required" >&2; exit 1; fi
if ! command -v aws >/dev/null; then echo "error: aws CLI required" >&2; exit 1; fi

if [[ ! -d "$PROD_TF_DIR" ]]; then
  echo "error: $PROD_TF_DIR not found" >&2; exit 1
fi

echo "==> Reading terraform outputs from $PROD_TF_DIR"
TF_OUTPUTS=$(cd "$PROD_TF_DIR" && terraform output -json 2>/dev/null || echo '{}')
if [[ "$TF_OUTPUTS" == "{}" ]]; then
  echo "warning: terraform output is empty — has \`terraform apply\` been run on envs/prod yet?" >&2
  if [[ "$MODE" == "--check" ]]; then exit 2; fi
fi

get_output() {
  local key=$1
  echo "$TF_OUTPUTS" | jq -r ".\"$key\".value // empty" 2>/dev/null
}

RDS_ENDPOINT=$(get_output rds_endpoint)
ACM_ARN=$(get_output acm_certificate_arn)        # informational; overlay no longer hardcodes
IRSA_AUTH=$(echo "$TF_OUTPUTS"     | jq -r '.service_irsa_role_arns.value."auth-svc"     // empty')
IRSA_TASKS=$(echo "$TF_OUTPUTS"    | jq -r '.service_irsa_role_arns.value."tasks-svc"    // empty')
IRSA_NOTIFIER=$(echo "$TF_OUTPUTS" | jq -r '.service_irsa_role_arns.value."notifier-svc" // empty')

echo ""
echo "==> Sanity-checking pre-filled prod overlay values"
EXPECTED_AUTH="arn:aws:iam::164856787183:role/usf-devops-prod-auth-svc"
EXPECTED_TASKS="arn:aws:iam::164856787183:role/usf-devops-prod-tasks-svc"
EXPECTED_NOTIFIER="arn:aws:iam::164856787183:role/usf-devops-prod-notifier-svc"
EXPECTED_BUCKET="usf-devops-alb-logs-prod-164856787183"

drift=0
check_eq() {
  local label=$1 actual=$2 expected=$3
  if [[ -z "$actual" ]]; then
    echo "  skip $label — terraform output not available"
  elif [[ "$actual" == "$expected" ]]; then
    echo "  ok   $label = $expected"
  else
    echo "  DRIFT $label"
    echo "       expected: $expected"
    echo "       actual:   $actual"
    drift=$((drift + 1))
  fi
}
check_eq "auth-svc IRSA"     "$IRSA_AUTH"     "$EXPECTED_AUTH"
check_eq "tasks-svc IRSA"    "$IRSA_TASKS"    "$EXPECTED_TASKS"
check_eq "notifier-svc IRSA" "$IRSA_NOTIFIER" "$EXPECTED_NOTIFIER"

ACTUAL_BUCKET=$(get_output alb_logs_bucket)
check_eq "ALB logs bucket"   "$ACTUAL_BUCKET" "$EXPECTED_BUCKET"

if (( drift > 0 )); then
  echo ""
  echo "ERROR: $drift drift(s) detected — the prod TF code may have changed naming convention." >&2
  echo "Update gitops/overlays/prod/* and this script to match." >&2
  exit 3
fi

echo ""
echo "==> Ensuring prod-db.calmloop.space CNAME → RDS endpoint"
if [[ -z "$RDS_ENDPOINT" ]]; then
  echo "  skip — RDS not yet applied"
elif [[ "$MODE" == "--dry-run" ]]; then
  echo "  would create CNAME prod-db.calmloop.space → $RDS_ENDPOINT"
else
  # Requires CLOUDFLARE_API_TOKEN env var with DNS:Edit scope.
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo "  warning: CLOUDFLARE_API_TOKEN not set; skipping CNAME setup" >&2
    echo "          (alternatively, terraform module dns/ creates this on apply)" >&2
  else
    ZONE_ID=$(curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones?name=calmloop.space" | jq -r '.result[0].id')
    if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
      echo "  ERROR: could not resolve Cloudflare zone ID for calmloop.space" >&2; exit 4
    fi
    curl -sS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H 'Content-Type: application/json' \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -d "{\"type\":\"CNAME\",\"name\":\"prod-db\",\"content\":\"$RDS_ENDPOINT\",\"ttl\":300,\"proxied\":false}" \
      >/dev/null
    echo "  prod-db.calmloop.space CNAME → $RDS_ENDPOINT"
  fi
fi

echo ""
if [[ "$MODE" == "--check" ]]; then
  echo "✓ prod overlay is in sync with TF outputs"
else
  echo "==> Done. Verify with: helm template t charts/auth-svc -f charts/auth-svc/values.yaml \\"
  echo "       -f gitops/overlays/prod/_common.yaml -f gitops/overlays/prod/auth-svc.yaml"
fi
