# End-to-end Demo Scripts

These walk through the three "wow moments" of this platform. Each is
self-contained and prints what's happening so you can narrate.

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

**Scenario:** A developer ships a buggy image. Argo Rollouts + Prometheus
analysis detect the regression and roll back automatically — no human in
the loop, no dropped requests.

```sh
# Find a broken image tag (any tag that doesn't exist works to simulate
# "image pull fail"; for a true "5xx storm" demo, build an image whose
# /healthz returns 200 but /api/* returns 500 and push it).
BAD_TAG=git-DEADBEEFFFFF

./tools/demo/demo-canary-rollback.sh dev auth-svc "$BAD_TAG"
```

What you'll see in ~2-5 minutes:
- Canary ReplicaSet spins up at 10% weight
- Prometheus AnalysisTemplate starts watching: `sum(rate(http_requests_total{code=~"5.."}))`
- Bad image → 5xx storms → success rate < 99% → AnalysisRun: Failed
- Argo Rollouts aborts, traffic pinned to stable RS, canary scaled to 0
- Rollout status: `Degraded`

The ArgoCD UI shows it visually. Grafana dashboard "Argo Rollouts" shows
the analysis trace.

## 2. Worker AMI rotation (Karpenter drift)

**Scenario:** AWS publishes a new Bottlerocket image. We need to roll
every worker node onto the new AMI without dropping requests.

```sh
./tools/demo/demo-ami-rotation.sh https://app.dev.calmloop.space
```

What you'll see:
- k6 traffic at constant 100 RPS in the background
- Diff: current AMI vs latest AMI in SSM
- You re-run `terraform apply` (no code change — the SSM data source
  resolves to the new image; the EC2NodeClass diff is what triggers
  Karpenter drift)
- Karpenter cordons one node, drains it (respecting PDBs), provisions
  a fresh node with the new AMI, then drops the old
- Repeats per node, ~3-5 minutes per node
- k6 final report: **`http_req_failed: 0.00%`**

## 3. RDS schema migration (expand-contract)

**Scenario:** You need to rename a column on a live table. Three releases
in a chain, each independently rollback-safe.

```sh
./tools/demo/demo-schema-migration.sh
```

The script prints the three-step plan:
1. **`v1.2.0` Expand**: `ALTER TABLE tasks ADD COLUMN name TEXT`; app
   reads `title`, double-writes `title` and `name`
2. **`v1.3.0` Migrate readers**: app reads `name` first, falls back to
   `title`; still double-writes
3. **`v1.4.0` Contract**: `ALTER TABLE tasks DROP COLUMN title`; app
   reads/writes only `name`

Each release goes through ArgoCD's PreSync migration Job. If the SQL
fails, ArgoCD aborts the sync and the previous ReplicaSet keeps serving
— the canary never starts. Demonstrate that with a deliberate-fail
migration like `ADD COLUMN x TEXT NOT NULL` on a non-empty table.

## Talking points (in case you're narrating live)

- **No human approves prod canary**: Prometheus does the math. Humans
  only set the SLO once.
- **One terraform apply patches the OS fleet**: no SSH, no green-blue
  cluster, no "schedule a maintenance window". Karpenter drift > MNG
  rolling update.
- **Migrations are pre-sync, not in-process**: app pods never run with
  a partially-migrated schema. If the migration fails, the new pods
  never start; old pods keep serving.
- **Image signatures verified at admission**: Kyverno in prod refuses
  any image not signed by our GitHub Actions OIDC identity. Replay
  attack mitigation comes for free from Rekor.
