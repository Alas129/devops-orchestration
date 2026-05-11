# Operational Scenarios

End-to-end procedures that exercise the platform's three flagship
zero-downtime guarantees. Run them during an incident to confirm a
control still works, or during code review to validate the rollback
path you just changed.

## Prereqs (one-time)

```sh
# 1. kubectl authed against the target cluster
aws eks update-kubeconfig --region us-east-1 --name usf-devops-nonprod

# 2. argo rollouts plugin
brew install argoproj/tap/kubectl-argo-rollouts

# 3. k6 (for zero-downtime probes)
brew install k6

# 4. Confirm the env is up
kubectl get nodes
kubectl -n argocd get applications
```

## 1. Canary auto-rollback

**Scenario:** A service ships with a regression. Argo Rollouts +
Prometheus analysis must detect it and roll back automatically — no
human in the loop, no dropped requests.

```sh
# Pick a tag that will fail (any tag that doesn't exist trips the
# "image pull" path; for a 5xx storm, build an image whose /healthz
# returns 200 but /api/* returns 500 and push it).
BAD_TAG=git-DEADBEEFFFFF

./tools/runbooks/canary-rollback.sh dev auth-svc "$BAD_TAG"
```

What you observe in ~2–5 minutes:
- Canary ReplicaSet spins up at 10% weight
- Prometheus AnalysisTemplate starts watching: `sum(rate(http_requests_total{code=~"5.."}))`
- Bad image → 5xx storms → success rate < 99% → AnalysisRun: Failed
- Argo Rollouts aborts, traffic pinned to stable RS, canary scaled to 0
- Rollout status: `Degraded`

The ArgoCD UI shows it visually. Grafana dashboard "Argo Rollouts" shows
the analysis trace.

## 2. Worker AMI rotation (Karpenter drift)

**Scenario:** AWS publishes a new Bottlerocket image; every worker node
needs to roll onto it. The change must be a single `terraform apply`
and must not drop a single in-flight HTTP request.

```sh
./tools/runbooks/ami-rotation.sh https://app.dev.calmloop.space
```

What you observe:
- k6 traffic at constant 100 RPS in the background
- Diff: current AMI vs latest AMI in SSM
- After you re-run `terraform apply` (no code change — the SSM data
  source resolves to the new image; the EC2NodeClass diff is what
  triggers Karpenter drift)
- Karpenter cordons one node, drains it (respecting PDBs), provisions
  a fresh node with the new AMI, then drops the old
- Repeats per node, ~3–5 minutes per node
- k6 final report: **`http_req_failed: 0.00%`**

## 3. RDS schema migration (expand → migrate readers → contract)

**Scenario:** A column needs to be renamed on a live table. Three
releases in a chain, each independently rollback-safe; the database
never spends a moment in a half-migrated state.

```sh
./tools/runbooks/schema-migration.sh
```

The script prints the three-step plan:
1. **`v1.2.0` Expand** — `ALTER TABLE tasks ADD COLUMN name TEXT`; app
   reads `title`, double-writes `title` and `name`
2. **`v1.3.0` Migrate readers** — app reads `name` first, falls back to
   `title`; still double-writes
3. **`v1.4.0` Contract** — `ALTER TABLE tasks DROP COLUMN title`; app
   reads/writes only `name`

Each release goes through ArgoCD's PreSync migration Job. If the SQL
fails, ArgoCD aborts the sync and the previous ReplicaSet keeps serving
— the canary never starts. Validate that with a deliberate-fail
migration like `ADD COLUMN x TEXT NOT NULL` on a non-empty table.

## What each procedure proves

- **canary-rollback** — Prometheus-driven automation is the single
  source of truth for "is this build safe?" Humans only set the SLO
  threshold once.
- **ami-rotation** — One `terraform apply` patches the entire fleet.
  No SSH, no blue/green cluster, no scheduled maintenance window.
  Karpenter drift beats Managed Node Group rolling update on speed
  and PDB-awareness.
- **schema-migration** — App pods never run with a partially-migrated
  schema. If the migration fails, the new pods never start; old pods
  keep serving. PreSync hook + expand-contract is the only safe way to
  evolve a hot database.

Combined with Kyverno's `verify-cosign-signatures` policy in prod, the
admission webhook also refuses any unsigned image at runtime — so a
supply-chain attack on ECR can't materialise as a running pod even if
the attacker bypasses CI signing.
