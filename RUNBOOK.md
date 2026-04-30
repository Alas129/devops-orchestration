# Operations Runbook

Practical procedures for Day 2 scenarios. Each section is self-contained —
follow the steps top-to-bottom, copy/paste commands as written.

## Table of contents

1. [Bootstrap (one-time)](#1-bootstrap-one-time)
2. [Day 2 — OS / security patching (worker AMI rotation)](#2-day-2--os--security-patching-worker-ami-rotation)
3. [Day 2 — RDS schema changes (zero-downtime)](#3-day-2--rds-schema-changes-zero-downtime)
4. [Promotion across envs](#4-promotion-across-envs)
5. [Rollback](#5-rollback)
6. [Verifying observability](#6-verifying-observability)
7. [Incident response — failed canary](#7-incident-response--failed-canary)

---

## 1. Bootstrap (one-time)

Run from your local laptop with admin AWS creds. After this, all further
applies happen via GitHub Actions OIDC.

```sh
# 1. State backend
cd infra/terraform/bootstrap
terraform init && terraform apply
# Note the bucket name from output

# 2. Shared (Route53, ECR, GitHub OIDC roles)
cd ../envs/_shared
echo 'domain_name = "your.domain.com"' > terraform.tfvars
terraform init -backend-config=backend.hcl    # use the bucket name from step 1
terraform apply

# 3. Pre-create SSM parameters (referenced by ExternalSecret)
aws ssm put-parameter --name /devops/grafana/github/client_id --value "<from GitHub OAuth App>" --type SecureString
aws ssm put-parameter --name /devops/grafana/github/client_secret --value "<from GitHub OAuth App>" --type SecureString
aws ssm put-parameter --name /devops/alertmanager/slack_webhook_url --value "<from slack incoming webhook>" --type SecureString
aws ssm put-parameter --name /devops/alertmanager/smtp_username --value "<SES SMTP user>" --type SecureString
aws ssm put-parameter --name /devops/alertmanager/smtp_password --value "<SES SMTP pass>" --type SecureString
aws ssm put-parameter --name /devops/auth-svc/jwt-secret --value "$(openssl rand -hex 32)" --type SecureString

# 4. Nonprod cluster + RDS + apps
cd ../nonprod
terraform init -backend-config=backend.hcl
terraform apply

# 5. Bake the RDS endpoint + per-env IRSA ARNs into gitops/overlays/*/_common.yaml
#    + gitops/overlays/*/<svc>.yaml. Open a PR with the replacements.

# 6. Prod (after nonprod is healthy)
cd ../prod
terraform init -backend-config=backend.hcl
terraform apply
```

---

## 2. Day 2 — OS / security patching (worker AMI rotation)

**Goal:** Roll all worker nodes onto a fresh Bottlerocket AMI without dropping
a single in-flight HTTP request.

**Mechanism:** Karpenter v1.x **drift detection**. When the EC2NodeClass'
`amiSelectorTerms` change, Karpenter cordons each node, drains it (respecting
PodDisruptionBudgets — pods that would violate PDB block drain), provisions
a replacement with the new AMI, and deletes the old node.

### Procedure

```sh
# 1. Start a synthetic load against the env you're rotating (use uat for the demo)
k6 run -e BASE_URL=https://app.uat.<your-domain> -e DURATION=10m tools/load-test/k6-zero-downtime.js &
K6_PID=$!

# 2. Find the current AMI and the latest available
CURRENT=$(terraform -chdir=infra/terraform/envs/nonprod output -raw current_bottlerocket_ami_id)
LATEST=$(aws ssm get-parameter \
  --name /aws/service/bottlerocket/aws-k8s-1.30/x86_64/latest/image_id \
  --query Parameter.Value --output text)
echo "current: $CURRENT  latest: $LATEST"

# 3. Open a PR bumping infra/terraform/envs/nonprod (the AMI ID is read from
#    SSM at plan time; re-running terraform apply alone is enough — the data
#    source picks up the new image_id and Terraform shows the diff on the
#    EC2NodeClass).
#
# This is a one-line change in practice; the diff is visible in `terraform plan`.
# Merge → terraform-apply.yaml fires → EC2NodeClass updated.

# 4. Watch Karpenter rotate nodes, one at a time
kubectl get nodes -w
# In a second terminal:
kubectl get pods -A -w | grep -v Running

# 5. After rotation completes, k6 should report 0 failed requests
wait $K6_PID
# Look for: "http_req_failed: 0.00%"
```

### Why not Managed Node Group rolling update?

Karpenter is faster, can mix spot/on-demand during the rotation, and respects
PDBs by default. MNG rolling update is the documented fallback if Karpenter
ever needs to be disabled.

---

## 3. Day 2 — RDS schema changes (zero-downtime)

**Goal:** Add a column / rename a column / drop a column on a live database
without breaking any in-flight requests.

**Mechanism:**
- Each service's chart includes a `Job` annotated as ArgoCD `PreSync`. The
  Job runs `golang-migrate` against the env's database BEFORE the new
  ReplicaSet rolls out. If the migration fails, ArgoCD aborts the sync and
  the previous ReplicaSet keeps serving.
- Schema changes follow **expand → migrate readers → contract** so each
  release is independently rollback-safe.

### Three-step rename example: `tasks.title` → `tasks.name`

| Release  | Migration                                                            | Code                                                                  | Rollback safe? |
|----------|----------------------------------------------------------------------|------------------------------------------------------------------------|----------------|
| `v1.2.0` | `ALTER TABLE tasks ADD COLUMN name TEXT;` + batched UPDATE backfill  | reads `title`, **double-writes** `title` and `name`                    | yes — `title` still present |
| `v1.3.0` | (none)                                                               | reads `name` first, falls back to `title`; still double-writes         | yes — both columns present |
| `v1.4.0` | `ALTER TABLE tasks DROP COLUMN title;`                               | reads/writes only `name`                                                | yes — v1.3.0 doesn't depend on `title` |

### How to run a migration end-to-end

```sh
# 1. Add the migration file
cat > apps/tasks-svc/migrations/0002_add_name.up.sql <<'SQL'
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS name TEXT;
UPDATE tasks SET name = title WHERE name IS NULL;
SQL

cat > apps/tasks-svc/migrations/0002_add_name.down.sql <<'SQL'
ALTER TABLE tasks DROP COLUMN IF EXISTS name;
SQL

# 2. Update the app code to dual-write title+name (release v1.2.0)
# 3. Conventional Commit:  `feat(tasks-svc): add name column (expand)`
# 4. Open PR, merge — release-please opens a Release PR
# 5. Merge the Release PR with prerelease=true → tag v1.2.0-rc.1 → UAT canary
# 6. After UAT bakes, merge the Release PR without prerelease → tag v1.2.0 → PROD canary
# 7. Watch ArgoCD UI: PreSync job runs the migration first, then canary begins
```

### Demonstrating a deliberate-fail migration (rubric bonus)

Push a migration like `ALTER TABLE tasks ADD COLUMN x TEXT NOT NULL;` (no
default, with existing rows). It will fail; ArgoCD will show the PreSync Job
in error, the Sync as blocked, and the old ReplicaSet still serving. Take a
screenshot for the demo.

---

## 4. Promotion across envs

| From → To  | Trigger                                                      | Workflow                                      |
|------------|--------------------------------------------------------------|-----------------------------------------------|
| dev        | Push to `main` (Conventional Commit)                         | `ci-<service>.yaml` builds + bumps overlay    |
| qa         | 00:00 UTC nightly cron                                       | `nightly-qa.yaml` copies dev tags to qa       |
| uat        | Tag `vX.Y.Z-rc.N` (release-please prerelease)               | `promote-uat.yaml` bumps uat overlay          |
| prod       | Tag `vX.Y.Z` (release-please non-prerelease)                | `promote-prod.yaml` bumps prod overlay        |

ArgoCD on each cluster watches its overlay directory and reconciles. Argo
Rollouts handles the canary / blue-green per service.

---

## 5. Rollback

ArgoCD keeps the last 10 revisions of each Application. To roll back:

```sh
# Via ArgoCD UI: app → History → pick previous revision → Rollback

# Or via CLI:
argocd app history prod-tasks-svc
argocd app rollback prod-tasks-svc <revision-id>
```

Argo Rollouts can also be rolled back with `kubectl argo rollouts undo
<rollout-name>`. This re-promotes the previous stable ReplicaSet without
touching Git.

For schema-driven rollback issues, see §3 — the expand-contract pattern
guarantees v1.N is always backwards-compatible with v1.N-1.

---

## 6. Verifying observability

```sh
# Grafana — should redirect to GitHub OAuth, not show a username/password form
open https://grafana.nonprod.<your-domain>

# Confirm OAuth-only:
curl -sSI https://grafana.nonprod.<your-domain>/login | head -1
# Expected: 302 to /login/github  (or the hosted GitHub authorize URL)

# Loki multi-service query (from Grafana Explore)
{namespace="prod"} |= "user_id"

# Prometheus: confirm node CPU/Mem/Disk dashboards
# Grafana → Dashboards → Node Exporter / Nodes → all three panels populated

# Alertmanager test (force a fake critical alert via CLI)
kubectl -n monitoring exec deploy/kube-prometheus-stack-operator -- \
  amtool alert add testalert severity=critical \
    --annotation="summary=runbook test" \
    --alertmanager.url=http://kube-prometheus-stack-alertmanager:9093
# Slack #devops-alerts should get a message; resolve with: amtool alert ... --end now
```

---

## 7. Incident response — failed canary

Argo Rollouts auto-aborts the canary when the Prometheus AnalysisTemplate
fails (success rate < 99% or p95 > 500ms over 2 min). Symptoms:

- ArgoCD app degraded
- `kubectl argo rollouts get rollout <svc> -n <ns>` shows status `Degraded`
  and last analysis result `Failure`

Steps:

```sh
# 1. Pull recent logs across all replicas
kubectl logs -n <ns> -l app.kubernetes.io/name=<svc> --tail=200 --all-containers

# 2. Confirm the failing condition in Grafana — open the service's RED dashboard

# 3. If it's a known-bad image, abort the rollout (forces 100% back to stable)
kubectl argo rollouts abort <svc> -n <ns>

# 4. To prevent reattempt while you investigate, pin the previous tag in
#    gitops/overlays/<env>/<svc>.yaml and merge a revert PR.
```
