# Production-Ready DevOps Orchestration

End-to-end DevOps platform on AWS demonstrating IaC, GitOps, zero-downtime
rollouts, automated Day 2 operations, and self-hosted observability.

## At a glance

- **3 Go microservices** (`auth-svc`, `tasks-svc`, `notifier-svc`) + **Next.js
  frontend**, all behind ALB+ACM with custom DNS.
- **2 EKS clusters**: `nonprod` (dev/qa/uat as namespaces) + `prod` (hard
  isolation: own VPC, IAM, RDS Multi-AZ).
- **All infra in Terraform**, state in S3+DynamoDB, applied by GitHub Actions
  via OIDC (no static AWS keys).
- **GitOps via ArgoCD** with **Argo Rollouts** (canary for backend, blue/green
  for frontend) and Prometheus-driven auto-rollback.
- **Promotion**: Conventional Commits → release-please → SemVer tags. PR merge
  to `main` deploys to dev; nightly cron promotes to qa; `vX.Y.Z-rc.N` tag
  deploys to uat; `vX.Y.Z` tag deploys to prod.
- **Day 2**: Karpenter + Bottlerocket drift detection rotates worker AMIs
  with zero dropped requests. golang-migrate + ArgoCD PreSync hook handles RDS
  schema changes via expand-contract.
- **Observability**: kube-prometheus-stack + Loki + Tempo, Grafana behind
  GitHub OAuth2 (no local accounts), Alertmanager → Slack + SES email.

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for deep-dives and
[`RUNBOOK.md`](./RUNBOOK.md) for Day 2 procedures.

## Repo layout

```
apps/             # Source for frontend + 3 Go microservices
charts/           # One Helm chart per workload (Rollout + PreSync migration Job + PDB + HPA + ServiceMonitor + Ingress)
gitops/           # ArgoCD Applications + per-env values overlays
infra/terraform/  # Modules + per-env composition (bootstrap / _shared / nonprod / prod)
.github/workflows # CI per service + release-please + terraform plan/apply
tools/load-test/  # k6 scripts for zero-downtime evidence
RUNBOOK.md        # Day 2 procedures (AMI rotation, schema migrations)
```

## First-time setup

Prerequisites that live outside Terraform (one-time, per-IdP, not ClickOps in
AWS):

1. A registered domain — set `var.domain_name` (e.g. `usfdevops.example.com`).
2. GitHub OAuth App for Grafana (Org → Settings → Developer settings → OAuth
   Apps). Callback `https://grafana.<env>.<domain>/login/github`. Client ID +
   secret stored in SSM at `/devops/grafana/github/{client_id,client_secret}`.
3. Slack incoming webhook (URL stored at SSM `/devops/alertmanager/slack_webhook_url`).
4. SES verified sender (e.g. `alerts@<domain>`) — Terraform creates the
   identity, but DNS owner confirms the verification record.

Then:

```sh
# 1. Bootstrap state backend (local state, run once)
cd infra/terraform/bootstrap && terraform init && terraform apply

# 2. Shared (Route53 data source, ECR repos, GitHub OIDC trust)
cd ../envs/_shared && terraform init && terraform apply

# 3. Nonprod
cd ../nonprod && terraform init && terraform apply

# 4. Prod (after nonprod is healthy)
cd ../prod && terraform init && terraform apply
```

After that, all subsequent applies happen via GitHub Actions on PR merge to
`main`.

## Verifying zero-downtime claims

```sh
# Run during a deploy or AMI rotation
k6 run tools/load-test/k6-zero-downtime.js
# Final report should show http_req_failed: 0.00%
```
