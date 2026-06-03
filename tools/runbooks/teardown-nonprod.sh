#!/usr/bin/env bash
# Tear down the usf-devops-nonprod environment on AWS.
#
# Scope: nonprod only. Preserves _shared, prod, the TF state bucket, the
# Cloudflare zone, and the apex domain registration. See the matching
# runbook (teardown-nonprod.md) for the reasoning behind each phase.
#
# Usage:
#   ./tools/runbooks/teardown-nonprod.sh            # interactive, confirms at each phase
#   ./tools/runbooks/teardown-nonprod.sh --yes      # skip per-phase confirmations
#   ./tools/runbooks/teardown-nonprod.sh --phase 4  # run a single phase (debug)
#
# Idempotent: re-run after a failure; phases skip cleanly when their work
# is already done.
#
# Prereqs: aws cli authed against account 164856787183, kubectl, helm,
# terraform >= 1.7, jq. Run from the repo root.

set -uo pipefail

REGION="us-east-1"
ACCOUNT="164856787183"
CLUSTER="usf-devops-nonprod"
TFDIR="infra/terraform/envs/nonprod"
TFVARS="terraform.tfvars"
APP_NAMESPACES=(dev qa uat argocd monitoring ai-bot)

YES=0
ONLY_PHASE=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --phase) shift; ONLY_PHASE="${1:-}" ;;
    --phase=*) ONLY_PHASE="${arg#--phase=}" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  esac
done

c_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

phase() {
  local n="$1"; shift
  if [[ -n "$ONLY_PHASE" && "$ONLY_PHASE" != "$n" ]]; then return 1; fi
  echo
  c_yellow "═══ Phase $n: $* ═══"
  if [[ $YES -ne 1 ]]; then
    read -r -p "  Run this phase? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { c_dim "  Skipped."; return 1; }
  fi
  return 0
}

# ── Phase 0: preflight ────────────────────────────────────────────────────
if phase 0 "Preflight — verify identity, cluster reachable"; then
  acct=$(aws sts get-caller-identity --query Account --output text)
  if [[ "$acct" != "$ACCOUNT" ]]; then
    c_red "Wrong AWS account: got $acct, expected $ACCOUNT. Bailing."
    exit 1
  fi
  c_green "AWS account ✓ ($acct)"

  if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
    if kubectl --context "arn:aws:eks:$REGION:$ACCOUNT:cluster/$CLUSTER" get ns >/dev/null 2>&1; then
      c_green "EKS API server reachable ✓"
    else
      c_yellow "EKS cluster exists but API is unreachable — Phases 1–3 will skip themselves."
    fi
  else
    c_yellow "EKS cluster $CLUSTER does not exist — skipping in-cluster phases."
  fi

  c_dim "Will destroy: EKS, RDS (no final snapshot), VPC, ACM, IRSA, ALBs, EBS volumes."
  c_dim "Will preserve: _shared, prod, TF state bucket, Cloudflare zone, domain registration."
fi

KCTX="arn:aws:eks:$REGION:$ACCOUNT:cluster/$CLUSTER"
k() { kubectl --context "$KCTX" "$@"; }
cluster_alive() { k get ns >/dev/null 2>&1; }

# ── Phase 1: quiet ArgoCD ─────────────────────────────────────────────────
if phase 1 "Scale ArgoCD controllers to 0 (stop self-heal)"; then
  if cluster_alive; then
    for sts in argocd-application-controller; do
      k -n argocd scale statefulset "$sts" --replicas=0 2>/dev/null || true
    done
    for d in argocd-applicationset-controller argocd-repo-server argocd-server argocd-redis argocd-notifications-controller; do
      k -n argocd scale deploy "$d" --replicas=0 2>/dev/null || true
    done
    c_green "ArgoCD paused."
  else
    c_dim "Cluster unreachable — skipping."
  fi
fi

# ── Phase 2: drain Ingresses, LB Services, PVCs ───────────────────────────
if phase 2 "Delete Ingresses, LoadBalancer Services, PVCs across app namespaces"; then
  if cluster_alive; then
    for ns in "${APP_NAMESPACES[@]}"; do
      k get ns "$ns" >/dev/null 2>&1 || continue
      c_dim "  ns=$ns"
      k -n "$ns" delete ingress --all --wait=false 2>/dev/null || true
      # LoadBalancer-type services (NLB drains too)
      k -n "$ns" get svc -o json 2>/dev/null \
        | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .metadata.name' \
        | xargs -r -n1 -I{} kubectl --context "$KCTX" -n "$ns" delete svc {} --wait=false 2>/dev/null || true
      k -n "$ns" delete pvc --all --wait=false 2>/dev/null || true
    done

    c_dim "  waiting up to 5 min for ALBs to drain…"
    for i in {1..60}; do
      remaining=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "length(LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')])" --output text 2>/dev/null || echo 0)
      [[ "$remaining" == "0" ]] && break
      printf '\r    k8s-* ALBs remaining: %s  ' "$remaining"
      sleep 5
    done
    echo
    c_green "ALB drain done."
  else
    c_dim "Cluster unreachable — skipping."
  fi
fi

# ── Phase 3: drain Karpenter nodes ────────────────────────────────────────
if phase 3 "Delete Karpenter NodePools / NodeClaims (drain EC2)"; then
  if cluster_alive; then
    k delete nodepool --all --wait=false 2>/dev/null || true
    k delete ec2nodeclass --all --wait=false 2>/dev/null || true
    k delete nodeclaim --all --wait=false 2>/dev/null || true
    c_dim "  waiting up to 5 min for Karpenter nodes to terminate…"
    for i in {1..60}; do
      remaining=$(aws ec2 describe-instances --region "$REGION" \
        --filters Name=instance-state-name,Values=running,pending \
                  "Name=tag:karpenter.sh/cluster,Values=$CLUSTER" \
        --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
      [[ "$remaining" == "0" ]] && break
      printf '\r    karpenter EC2 still running: %s  ' "$remaining"
      sleep 5
    done
    echo
    c_green "Karpenter drained."
  else
    c_dim "Cluster unreachable — skipping."
  fi
fi

# ── Phase 4: terraform destroy pass 1 (K8s-resident modules) ──────────────
if phase 4 "terraform destroy — K8s-side modules (argocd, monitoring, platform)"; then
  pushd "$TFDIR" >/dev/null
  if [[ ! -f "$TFVARS" ]]; then
    c_red "Missing $TFDIR/$TFVARS — copy from example.tfvars and fill in state_bucket + cloudflare_api_token."
    popd >/dev/null
    exit 1
  fi
  terraform destroy -auto-approve -var-file="$TFVARS" \
    -target=module.argocd \
    -target=module.monitoring \
    -target=module.platform \
    || c_yellow "  Pass 1 returned non-zero — continuing; pass 2 will catch leftovers."
  popd >/dev/null
fi

# ── Phase 5: terraform destroy pass 2 (everything else) ───────────────────
if phase 5 "terraform destroy — RDS / EKS / VPC / IRSA / ACM (deletion_protection=false)"; then
  pushd "$TFDIR" >/dev/null
  terraform destroy -auto-approve -var-file="$TFVARS" \
    -var deletion_protection=false
  rc=$?
  popd >/dev/null
  if [[ $rc -ne 0 ]]; then
    c_red "  terraform destroy failed (rc=$rc). Check the trace above; common causes:"
    c_red "    - orphan ENIs blocking VPC delete: run Phase 6 then retry this phase."
    c_red "    - RDS deletion protection still on: aws rds modify-db-instance"
    c_red "        --db-instance-identifier $CLUSTER --no-deletion-protection --apply-immediately"
    c_red "    - helm_release waits forever: terraform state rm 'module.platform.helm_release.<x>' then retry."
    exit $rc
  fi
fi

# ── Phase 6: manual cleanup of out-of-TF resources ────────────────────────
if phase 6 "Manual cleanup (SSM, Secrets Manager, log groups, orphan ENIs/EBS)"; then
  for p in /devops/alertmanager/slack_webhook_url /devops/grafana/github/client_secret; do
    aws ssm delete-parameter --region "$REGION" --name "$p" 2>/dev/null \
      && c_dim "  deleted SSM $p" \
      || c_dim "  SSM $p already gone"
  done

  aws secretsmanager delete-secret --region "$REGION" \
    --secret-id "$CLUSTER/rds/master" --force-delete-without-recovery 2>/dev/null \
    && c_dim "  deleted Secrets Manager $CLUSTER/rds/master" \
    || c_dim "  $CLUSTER/rds/master already gone or pending"

  for lg in \
    "/aws/eks/$CLUSTER/cluster" \
    "/aws/rds/instance/$CLUSTER/postgresql" \
    "/aws/karpenter/$CLUSTER"; do
    aws logs delete-log-group --region "$REGION" --log-group-name "$lg" 2>/dev/null \
      && c_dim "  deleted log group $lg" \
      || c_dim "  log group $lg already gone"
  done

  c_dim "  sweeping orphan ENIs…"
  aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=description,Values=*$CLUSTER*" \
    --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' \
    --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r eni; do
        [[ -z "$eni" ]] && continue
        aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null \
          && c_dim "    deleted ENI $eni"
      done

  c_dim "  sweeping orphan EBS volumes…"
  aws ec2 describe-volumes --region "$REGION" \
    --filters Name=status,Values=available \
              "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r v; do
        [[ -z "$v" ]] && continue
        aws ec2 delete-volume --region "$REGION" --volume-id "$v" 2>/dev/null \
          && c_dim "    deleted volume $v"
      done

  c_green "Manual cleanup done."
fi

# ── Phase 7: verify ───────────────────────────────────────────────────────
if phase 7 "Verify (should all be empty or 0)"; then
  echo
  c_yellow "EKS clusters (expect prod only):"
  aws eks list-clusters --region "$REGION" --output table
  echo
  c_yellow "RDS instances (expect prod only):"
  aws rds describe-db-instances --region "$REGION" \
    --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]' --output table
  echo
  c_yellow "EC2 instances still tagged with the nonprod cluster:"
  aws ec2 describe-instances --region "$REGION" \
    --filters Name=instance-state-name,Values=running,pending \
              "Name=tag:karpenter.sh/cluster,Values=$CLUSTER" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
  echo
  c_yellow "k8s-* ALBs (expect none for nonprod):"
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].[LoadBalancerName,State.Code]" \
    --output table
  echo
  c_green "Teardown complete. _shared and TF state bucket preserved; you can re-apply nonprod any time."
fi
