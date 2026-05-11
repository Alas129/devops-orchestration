# Architecture & Decisions

## High-level diagram

```
                     ┌────────── Route53 hosted zone (shared) ──────────┐
                     │  *.dev.<dom>  *.qa.<dom>  *.uat.<dom>  *.prod    │
                     └─────────────┬────────────────────┬───────────────┘
                                   │                    │
                          ALB+ACM Ingress         ALB+ACM Ingress
                                   │                    │
              ┌─────────── EKS nonprod ──────────┐  ┌─ EKS prod ─┐
              │  ns:dev   ns:qa   ns:uat         │  │  ns:prod    │
              │  frontend (Next.js, Blue/Green)  │  │  identical  │
              │  auth-svc / tasks-svc / notifier │  │  layout     │
              │       (Go, Argo Rollouts canary) │  │             │
              │  NATS JetStream                  │  │             │
              │  ArgoCD / kube-prom / Loki / Tempo│  │             │
              │  Karpenter (Bottlerocket)        │  │             │
              └─────────────┬────────────────────┘  └──────┬──────┘
                            │                              │
                     RDS PG16 single-AZ              RDS PG16 Multi-AZ
                     3 logical DBs (dev/qa/uat)      1 DB (prod)
```

## Decision log

### 2 clusters, not 4
- EKS control plane is $73/mo per cluster — 4 clusters = $292/mo before any
  nodes. nonprod sharing 1 cluster keeps prod's blast radius hard while
  letting Karpenter consolidate dev/qa/uat onto 2-3 spot nodes.
- Hard prod boundary: separate VPC, separate node IAM role, separate RDS
  instance, separate ArgoCD instance.
- nonprod isolation: namespaces + NetworkPolicy + per-env Postgres role +
  per-env logical database.

### Karpenter + Bottlerocket
- Bottlerocket: container-optimized, immutable, A/B atomic update, smaller
  attack surface than AL2023. SSM-managed, no SSH by default.
- Karpenter v1.x: drift detection means changing AMI ID in Terraform alone is
  enough to trigger PDB-respecting node rotation. This is the entire Day 2
  patching story collapsed into `terraform apply`.

### ArgoCD + Argo Rollouts (not native Deployment + flux)
- Pull-based GitOps means CI never holds AWS write credentials beyond the
  ECR push role. ArgoCD reconciles from inside the cluster.
- Argo Rollouts canary with Prometheus AnalysisTemplate auto-rolls back on
  SLO violation — strong "zero dropped requests" story.
- Frontend uses blue/green because Next.js client-side caching breaks under
  canary mixing.

### release-please for Conventional-Commits → SemVer
- Resolves the spec's contradictory "Conventional Commits (e.g. RC1, RC2)"
  phrase: commit messages drive *what* the version is; tags drive *where* it
  deploys.
- Promotion table:
  - Merge to `main` → dev
  - Nightly cron → qa
  - `vX.Y.Z-rc.N` tag → uat
  - `vX.Y.Z` tag → prod

### Loki, not ELK
- Indexes labels only; ~10× lower storage cost than ELK on EKS.
- Same Grafana UI as metrics — single pane of glass.

### Grafana GitHub OAuth (not Google/Okta)
- Repo lives on GitHub; org membership is already the source of truth for
  who should access ops dashboards.
- `disable_login_form = true` removes username/password login entirely.

## Trade-offs explicitly accepted

- **Single NAT in nonprod**: an AZ outage takes nonprod offline. Acceptable —
  nonprod has no SLA. Prod gets one NAT per AZ.
- **Spot for nonprod nodes**: spot interruptions handled by Karpenter's
  interruption queue and PDBs.
- **ALB TLS termination**: pods speak HTTP inside the cluster. If end-to-end
  TLS is required, add a cert-manager-issued internal cert and a sidecar — not
  done by default to keep the platform simple.
- **NATS as stateful workload**: 1Gi PVC. Justifies notifier-svc's existence
  as a real async consumer instead of a webhook recipient.
- **App secrets in SSM, not Secrets Manager**: SSM Parameter Store is free
  for standard tier and the per-service IRSA role grants `ssm:GetParameter`
  on `/devops/*`. RDS master credentials are the one exception — they live
  in Secrets Manager because RDS rotation hooks expect that shape. A real
  org would standardise on one of the two.

## Cloud-account topology (today vs. real-world prod)

Today everything lives in **one AWS account**. That keeps the cost and
cognitive load low for a single-team deployment, but it's not what a
larger org would do.
The Terraform layout (`bootstrap` / `_shared` / `nonprod` / `prod`)
deliberately mirrors how it should split tomorrow, so the migration is
mostly "move a state file" rather than a rewrite.

```
                                  ┌────────────────────────────┐
                                  │  AWS Organizations master  │
                                  │  (billing, OUs, SCPs)      │
                                  └─────────────┬──────────────┘
                                                │
              ┌─────────────────┬───────────────┴────────────────┬─────────────────────┐
              │                 │                                │                     │
         ┌────▼─────┐      ┌────▼─────────┐               ┌──────▼────────┐    ┌───────▼───────┐
         │  Audit   │      │ Shared svcs  │               │   Nonprod     │    │     Prod      │
         │ account  │      │   account    │               │   account     │    │   account     │
         ├──────────┤      ├──────────────┤               ├───────────────┤    ├───────────────┤
         │GuardDuty │      │  ECR (all    │               │ EKS nonprod   │    │ EKS prod      │
         │Sec Hub   │      │   images,    │ ◄─ pulls ──── │ RDS single-AZ │    │ RDS Multi-AZ  │
         │AWS Config│      │   replicate  │ ◄─ pulls ────                      │ ─────────────►
         │CloudTrail│      │   to DR rgn) │                                    │  AWS Backup    │
         │ log lake │      │ KMS shared   │                                    │  cross-region  │
         │ Athena   │      │ OIDC IAM     │                                    └────────────────┘
         └──────────┘      │   (GHA roles)│
                          └──────────────┘
```

Today's mapping:

| Terraform composition | Today (single account) | Real org |
|---|---|---|
| `bootstrap` (state backend) | management account | management account |
| `_shared` (ECR, OIDC, security baseline) | management account | "Shared services" + "Audit" accounts |
| `nonprod` | management account | dedicated nonprod account |
| `prod` | management account | dedicated prod account |

To migrate to multi-account later: add an AWS Organizations + Control
Tower (or Terraform AFT) layer on top, move the `_shared` Terraform
state into a fresh "shared-services" account, and update the OIDC
trust to cross-account assume. The application Terraform doesn't need
to change.
