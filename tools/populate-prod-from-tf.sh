#!/usr/bin/env bash
# Populate prod overlay placeholders from `terraform output` after a successful
# `terraform apply` on envs/prod. Idempotent: re-running with up-to-date TF
# state will leave the overlay unchanged (sed only replaces REPLACE_* tokens).
#
# Usage:
#   tools/populate-prod-from-tf.sh                 # uses envs/prod state
#   tools/populate-prod-from-tf.sh --dry-run       # print what would change
#
# Sequence the user runs:
#   1. cd infra/terraform/envs/prod && terraform apply
#   2. cd ../../../..                && tools/populate-prod-from-tf.sh
#   3. git diff gitops/overlays/prod/   # review
#   4. git add gitops/overlays/prod && git commit && git push
#   5. push a stable tag (v1.0.0) to trigger promote-prod.yaml
set -euo pipefail

DRY_RUN=${1:-}
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROD_TF_DIR="$REPO_ROOT/infra/terraform/envs/prod"
OVERLAY_DIR="$REPO_ROOT/gitops/overlays/prod"

if ! command -v jq >/dev/null; then
    echo "error: jq required" >&2; exit 1
fi
if [[ ! -d "$PROD_TF_DIR" ]]; then
    echo "error: $PROD_TF_DIR not found" >&2; exit 1
fi

echo "==> Fetching terraform outputs from $PROD_TF_DIR"
TF_OUTPUTS=$(cd "$PROD_TF_DIR" && terraform output -json)

# Required outputs — `terraform output -json` returns {} if state is empty,
# so a missing key signals "prod has not been applied yet".
get_output() {
    local key=$1
    local value
    value=$(echo "$TF_OUTPUTS" | jq -r ".\"$key\".value // empty")
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "error: terraform output '$key' is missing — has \`terraform apply\` succeeded on envs/prod?" >&2
        exit 1
    fi
    echo "$value"
}

RDS_ENDPOINT=$(get_output rds_endpoint)
ACM_ARN=$(get_output acm_certificate_arn)
ALB_LOGS_BUCKET=$(get_output alb_logs_bucket)

# IRSA ARNs are a map keyed by service name (see envs/prod/outputs.tf).
IRSA_AUTH=$(echo "$TF_OUTPUTS"     | jq -r '.service_irsa_role_arns.value."auth-svc"     // empty')
IRSA_TASKS=$(echo "$TF_OUTPUTS"    | jq -r '.service_irsa_role_arns.value."tasks-svc"    // empty')
IRSA_NOTIFIER=$(echo "$TF_OUTPUTS" | jq -r '.service_irsa_role_arns.value."notifier-svc" // empty')
for v in "$IRSA_AUTH" "$IRSA_TASKS" "$IRSA_NOTIFIER"; do
    if [[ -z "$v" ]]; then
        echo "error: service_irsa_role_arns missing one of auth-svc/tasks-svc/notifier-svc" >&2; exit 1
    fi
done

# `sed -i ''` is the BSD/macOS form; GNU sed wants `sed -i`. Detect.
if sed --version >/dev/null 2>&1; then SED_INPLACE=(-i); else SED_INPLACE=(-i ''); fi

apply_sed() {
    local file=$1 token=$2 replacement=$3
    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        if grep -q "$token" "$file"; then
            echo "  $file: $token -> $replacement"
        fi
    else
        sed "${SED_INPLACE[@]}" "s|$token|$replacement|g" "$file"
    fi
}

echo "==> Populating $OVERLAY_DIR"
apply_sed "$OVERLAY_DIR/_common.yaml"     REPLACE_RDS_ENDPOINT          "$RDS_ENDPOINT"
apply_sed "$OVERLAY_DIR/_common.yaml"     REPLACE_PROD_ACM_ARN          "$ACM_ARN"
apply_sed "$OVERLAY_DIR/_common.yaml"     REPLACE_PROD_ALB_LOGS_BUCKET  "$ALB_LOGS_BUCKET"
apply_sed "$OVERLAY_DIR/auth-svc.yaml"     REPLACE_PROD_AUTH_SVC_IRSA_ARN     "$IRSA_AUTH"
apply_sed "$OVERLAY_DIR/tasks-svc.yaml"    REPLACE_PROD_TASKS_SVC_IRSA_ARN    "$IRSA_TASKS"
apply_sed "$OVERLAY_DIR/notifier-svc.yaml" REPLACE_PROD_NOTIFIER_SVC_IRSA_ARN "$IRSA_NOTIFIER"

if [[ "$DRY_RUN" != "--dry-run" ]]; then
    remaining=$(grep -rl "REPLACE_" "$OVERLAY_DIR" 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
        echo "warning: REPLACE_ tokens still present in:" >&2
        echo "$remaining" >&2
        exit 2
    fi
    echo "==> Done. Review with: git diff gitops/overlays/prod/"
fi
