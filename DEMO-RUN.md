# CI/CD Demo Run Sheet

A pure execution checklist for a 25-minute live demo of the full
**Dev → QA → UAT** Git-driven promotion pipeline. Pick ONE service, make
a one-line change, watch it flow through every gate.

Optimised for screen-share + narration. Each step has:
- exact commands (copy-pasteable)
- expected output (so you know it worked)
- time budget
- what to say while waiting

---

## 0. Pre-flight (do this 5 min BEFORE the demo)

### 0.1 Open these browser tabs (in this order, left-to-right)

| Tab | URL | What you'll show |
|---|---|---|
| 1 | https://app.dev.calmloop.space | The actual app (proof "it works") |
| 2 | https://github.com/Alas129/devops-orchestration/actions | CI runs as they trigger |
| 3 | https://argocd.nonprod.calmloop.space | GitOps sync + canary visual |
| 4 | https://grafana.nonprod.calmloop.space/dashboards | Node Exporter / Pod dashboards (Rubric CPU/Mem/Disk evidence) |
| 5 | https://grafana.nonprod.calmloop.space/explore | Loki logs (multi-service query, Rubric evidence) |
| 6 | Slack `#devops-alerts` | Pipeline events stream in real-time |

> **Why 6 tabs?** Each tab maps to a specific Rubric line — see § "Observability touchpoints per step" below.

### 0.2 Verify baseline (8 pods, all 1/1 Running)

```bash
kubectl --context nonprod -n dev get pods
```

Expected: 8 pods, all `1/1 Running`.

If any are `0/1`, **stop**, fix the IAM token issue (described in
CLAUDE.md → Sharp edges), then start the demo.

### 0.3 Login to ArgoCD UI

Click GitHub OAuth on Tab 3. Filter sidebar → Project = `nonprod` (hides
the orphan `root` app). Sort = name.

### 0.4 Observability layer — three places to look during the demo

| Surface | What it shows | When it lights up |
|---|---|---|
| **ArgoCD UI** (Tab 3) | GitOps sync state per Application, Rollout canary visual, AnalysisRun results | Every time you push a commit that changes a `gitops/overlays/**` file (auto-bump, nightly-qa, promote-uat) |
| **Grafana Dashboards** (Tab 4) | Cluster CPU/Mem/Disk per node + per pod, Argo Rollouts panels | Continuously. Pre-pick: *Node Exporter / Nodes* and *Kubernetes / Compute Resources / Pod* |
| **Grafana Explore → Loki** (Tab 5) | Logs from all 4 services in one query | When demonstrating multi-service log query (§3.5 alt) |
| **Slack `#devops-alerts`** (Tab 6) | Lifecycle events: 🟡 sync started, ✅ deployed, ❌ failed, 🚨 degraded; promotion events: 🚀 promote start, 🟣 awaiting approval, 🟢 success, 🔴 fail | Every CI/CD milestone. Pinned to the channel so it scrolls during the demo. |

**Emoji legend** (so the evaluator can scan Slack at a glance):
- 🟡 ⏳ in progress / awaiting approval
- 🟢 ✅ success / deployed
- 🟣 🎉 production release
- 🔴 ❌ failed
- 🚨 critical alert (CPU/Mem/Disk threshold breach)

### 0.5 Confirm demo accounts work

```bash
curl -s -X POST https://app.dev.calmloop.space/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"demo@calmloop.space","password":"Pass1234!"}' \
  | grep -o '"token":"[^"]*"' | head -c 30; echo
```

Expected: `"token":"eyJhbGciOiJIUzI1NiIsInR5cC...`

---

## 1. The change (1 min)

We'll change ONE visible log line in auth-svc. Tiny, but rebuilds the
image and ripples through every step.

### 1.1 New branch

```bash
git checkout main && git pull
git checkout -b demo/$(date +%Y%m%d)
```

### 1.2 Edit the file

Open `apps/auth-svc/cmd/server/main.go`. Find the line that logs
`"listening"`. Change the message to add a version annotation:

**Find:**
```go
slog.Info("listening", "addr", ":"+port)
```

**Change to:**
```go
slog.Info("listening", "addr", ":"+port, "build", "demo-run-1")
```

Or use sed:
```bash
sed -i '' 's/"listening", "addr", ":"+port)/"listening", "addr", ":"+port, "build", "demo-run-1")/' apps/auth-svc/cmd/server/main.go
```

Verify diff is exactly 1 line:
```bash
git diff --stat
```

Expected:
```
 apps/auth-svc/cmd/server/main.go | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
```

### 1.3 Commit

```bash
git add apps/auth-svc/cmd/server/main.go
git commit -m "feat(auth-svc): annotate startup log with build marker

Visible-in-logs marker for demo runs — confirms the new image is the
one serving traffic after canary completes."
```

---

## 2. PR → CI (5 min)

### 2.1 Push branch + open PR

```bash
git push -u origin HEAD
gh pr create --fill
```

**What to say** while CI runs:
> "GitHub now runs 6+ workflows in parallel — the per-service Go CI, CodeQL
> for security, gitleaks for credentials, chart-validate for K8s YAML.
> The big one is the per-service CI: Go test, vet, lint, gosec SAST, then
> Docker build, Trivy CVE scan, Cosign keyless signing via OIDC, SBOM
> attestation, push to ECR. **All of this happens BEFORE we merge.**"

### 2.2 Watch CI

```bash
gh pr checks --watch
```

Expected end state: `All checks were successful` (10 successful, 2 neutral).
The 2 neutral are Code Scanning aggregators — not failures.

> **👀 Where to look during this step**
> - **Tab 2 (GitHub Actions)**: see 6 workflows turn green one by one
> - **Slack**: nothing yet (Slack only fires on promotion + ArgoCD events, not per-service PR CI — by design, otherwise it'd be noise)

### 2.3 What's at ECR now (proof of build)

```bash
SHA=$(git rev-parse --short=12 HEAD)
aws ecr describe-images --repository-name usf-devops/auth-svc \
  --image-ids imageTag=git-$SHA --region us-east-1 \
  --query 'imageDetails[0].{Tags:imageTags,Pushed:imagePushedAt,SizeMB:imageSizeInBytes}'
```

**What to say:**
> "The image already exists in ECR, with a `git-<sha>` tag. It's already
> Cosign-signed and SBOM-attested. The merge step won't rebuild anything —
> it'll just bump a YAML line."

---

## 3. Merge → dev rollout (10 min)

### 3.1 Merge

```bash
gh pr merge --squash --delete-branch
git checkout main && git pull
```

### 3.2 Watch the auto-bump commit appear

```bash
# wait ~2 min for CI to build on main + push the bump commit
gh run watch
git pull
git log --oneline -3
```

Expected top commit:
```
<sha> chore(dev): bump auth-svc to git-<sha12> (sha256:...) [skip ci]
```

**What to say:**
> "Notice the `[skip ci]` — this prevents the auto-bump itself from
> triggering CI again, which would loop forever. The bot uses a PAT
> because the default `GITHUB_TOKEN` can't push to a protected branch."

### 3.3 ArgoCD picks it up — switch to UI

Tab 3 (ArgoCD). Filter `env=dev`. **`dev-auth-svc` card** will turn
`OutOfSync` (yellow), then `Syncing` (blue), then back to `Synced`.

Click into `dev-auth-svc` → resource tree → click the **Rollout** node.

**What to say:**
> "Argo Rollouts is doing a canary: 10% traffic → wait → AnalysisRun
> queries Prometheus for success-rate and p95 latency → if green, ramp
> to 25%, 50%, 100%. If any AnalysisRun fails, automatic rollback. No
> human in the loop."

> **👀 Where to look during this step (3 surfaces at once)**
> - **Tab 3 (ArgoCD)**: `dev-auth-svc` card pulse-cycles 🟡 OutOfSync → 🔵 Syncing → 🟢 Synced. Click in → Rollout node → watch the canary step bar fill 10% → 25% → 50% → 100%
> - **Tab 4 (Grafana)** → search dashboard "**Kubernetes / Compute Resources / Pod**" → namespace=dev, pod=auth-svc-* → watch new pod's CPU climb as it takes traffic during canary
> - **Tab 6 (Slack)**: expect 2 messages:
>   - 🟡 `Sync started — dev-auth-svc → dev` (when ArgoCD begins applying)
>   - 🟢 `Deployed — dev-auth-svc → dev` (when canary completes + health=Healthy)

### 3.4 Watch new pods replace old ones

In a terminal:
```bash
kubectl --context nonprod -n dev get pods -l app.kubernetes.io/name=auth-svc -w
```

Expected over ~8 min:
```
auth-svc-<old-rs>-...    1/1   Running   0   3h
auth-svc-<old-rs>-...    1/1   Running   0   3h
auth-svc-<new-rs>-...    0/1   Pending   0   0s     ← canary creates new pod
auth-svc-<new-rs>-...    0/1   ContainerCreating
auth-svc-<new-rs>-...    1/1   Running   0   10s
... (AnalysisRun pauses for ~2 min)
auth-svc-<new-rs>-...    1/1   Running   0   2m    ← second canary pod
... (more analysis)
auth-svc-<old-rs>-...    1/1   Terminating          ← old pods scale down
auth-svc-<old-rs>-...    Terminated
```

Ctrl-C when both new RS pods are Running and old ones are gone.

### 3.5 Confirm the new log line is live (the visible proof)

```bash
kubectl --context nonprod -n dev logs -l app.kubernetes.io/name=auth-svc --tail=2 \
  --max-log-requests=5 | grep listening
```

Expected:
```
{"time":"...","level":"INFO","msg":"listening","addr":":8080","build":"demo-run-1"}
```

**The `"build":"demo-run-1"` is the smoking gun** — the new code is
serving traffic. Before this demo it didn't exist.

> **👀 Bonus: prove it in Grafana too (Rubric "centralized logging" evidence)**
>
> Switch to Tab 5 (Grafana Explore → Loki datasource). Run:
> ```logql
> {namespace="dev",app="auth-svc"} |= "build" | json
> ```
> You'll see the same `build=demo-run-1` log line in Grafana — proves Loki + Promtail are scraping pod stdout end-to-end and indexing it by Kubernetes labels.

### 3.6 Confirm the app still works

```bash
curl -s -X POST https://app.dev.calmloop.space/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"demo@calmloop.space","password":"Pass1234!"}' \
  | grep -o '"token"'
```

Expected: `"token"` (login still works → canary rolled with zero downtime).

---

## 4. Dev → QA (30 sec)

### 4.1 Trigger the nightly promote manually

```bash
gh workflow run nightly-qa.yaml
sleep 8
gh run list --workflow=nightly-qa.yaml --limit 1
```

Expected: top row `in_progress` or `completed success`, event `workflow_dispatch`.

### 4.2 See the qa overlay updated

```bash
gh run watch       # blocks ~14 sec
git pull
grep tag gitops/overlays/qa/auth-svc.yaml
```

Expected:
```
  tag: git-<the-same-sha12-as-dev>
```

**What to say:**
> "QA is now identical to dev. No image rebuild — just YAML edits.
> Production-grade pipelines never re-build for promotion; they promote
> immutable image refs."

> **👀 Slack — pipeline events are visible**
> - 🟡 `Started — nightly-qa · promoting dev → qa` (workflow start)
> - 🟢 `Success — QA promoted from dev` (workflow end, with bullets: "all 4 services bumped", "ArgoCD will reconcile within ~3min")
> - Then 4× 🟡 `Sync started — qa-{svc} → qa` and 4× 🟢 `Deployed — qa-{svc} → qa` from ArgoCD as each qa Application reconciles

### 4.3 ArgoCD rolls qa (skip narration if running long)

`dev-auth-svc` and `qa-auth-svc` will both show the same image now.
ArgoCD will run canary on qa identically to dev.

---

## 5. QA → UAT via release tag (30 sec)

### 5.1 Pull then tag

```bash
git pull   # important — nightly-qa just pushed a commit
TAG="v0.1.0-rc.$(date +%H%M)"   # unique per demo, e.g. v0.1.0-rc.1430
git tag $TAG -m "Demo release candidate"
git push --tags
```

### 5.2 Watch promote-uat

```bash
gh run list --workflow=promote-uat.yaml --limit 1
gh run watch
```

Expected: ~25 sec, `completed success`.

**What to say:**
> "Three gates fired:
> 1. The workflow only triggers on tags matching `v*-rc.*` — typo-proof.
> 2. **Cosign verify**: every image referenced in qa overlay must have a
>    valid Sigstore signature in Rekor. If someone manually pushed a
>    rogue image to ECR, this step fails the whole release.
> 3. The bump step copies qa overlay → uat overlay verbatim. The release
>    tag is just a *pointer* to which moment in QA we're freezing."

> **👀 Slack — release event has its own color**
> - 🟡 `Started — promote → UAT triggered by tag v0.1.0-rc.XXXX`
> - 🟢 `Success — UAT release v0.1.0-rc.XXXX deployed` with bullets "4/4 cosign signatures verified", "ArgoCD will reconcile UAT in ~30s"
> - If cosign verify fails (rogue image): 🔴 `Failed — promote → UAT failed for v0.1.0-rc.XXXX` — this is the only message in the channel between yellow and green, instantly visible

### 5.3 Verify uat overlay

```bash
git pull
grep tag gitops/overlays/uat/auth-svc.yaml
```

Expected: the same `git-<sha12>` tag we've been tracking all demo.

---

## 5.4 Observability deep-dive (optional, 2 min — only if time permits)

After UAT is green, do a mini-Observability tour. This satisfies multiple
Rubric lines (CPU/Mem/Disk dashboards, multi-service logs, OAuth-only Grafana,
Slack alerts).

### A. Show CPU/Mem/Disk per node (Rubric: "Dashboard must track CPU, Memory, and Disk Space for all nodes")

Tab 4 → Dashboards → Browse → **"Node Exporter / Nodes"** → time = Last 30 minutes.

Point out: 3-4 lines on each panel — one per EKS worker. The CPU panel uses
exactly the same `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100`
expression as the `NodeCPUCriticallyHigh` alert.

### B. Show multi-service log query (Rubric: "centralized queries across the backend and all 3 microservices")

Tab 5 → Explore → Loki datasource → paste:

```logql
{namespace="dev"} |= "listening" | json | line_format "{{.app}} {{.msg}}"
```

Point out: one query, log lines from auth-svc + tasks-svc + notifier-svc +
frontend interleaved. The `{{.app}}` label comes from Promtail's
`kubernetes_pod_label_app_kubernetes_io_name` relabel rule.

### C. Show OAuth-only login (Rubric: "OAuth2 is the only way to access Grafana")

Sign out of Grafana (top-right user menu). On the login page show:

- No username/password form (`disable_login_form: true`)
- Only "Sign in with GitHub" button visible
- (Optional) View Grafana ConfigMap to show `auth.basic.enabled = false`:
  ```bash
  kubectl --context nonprod -n monitoring get configmap kube-prometheus-stack-grafana \
    -o jsonpath='{.data.grafana\.ini}' | grep -A1 "\[auth"
  ```

### D. Show a real alert fire (Rubric: "Alerts: Email and/or Slack")

Live-trip an alert (recovery is just edit-back):

```bash
kubectl --context nonprod -n monitoring edit prometheusrule node-resource-critical
# In editor: change `> 90` to `> 1` on NodeCPUCriticallyHigh, save.
```

Wait 5–6 minutes (`for: 5m` window) → Slack `#devops-alerts` lights up with
🚨 `[FIRING] NodeCPUCriticallyHigh` message. Restore the threshold afterwards.

(For a quicker demo, do this BEFORE Step 1 so the alert fires while the rest of
the pipeline runs in the background.)

---

## 6. Wrap-up (1 min)

### 6.1 Final state across all envs

```bash
for env in dev qa uat; do
  echo "$env: $(grep tag gitops/overlays/$env/auth-svc.yaml | head -1)"
done
```

Expected: all three envs at the same `git-<sha12>` — your one-line code
change has reached UAT through 3 automated gates with 0 manual edits to
manifests.

### 6.2 The narrative summary

> "**You watched 12 commands.** I created a branch, edited 1 line,
> opened a PR, merged it, triggered the qa promote, and pushed a tag.
> Every other action — test, scan, sign, push to ECR, edit YAML,
> rollout, canary, AnalysisRun, signature verification — was automated.
>
> If any of those automated steps had failed — bad test, CVE in a
> dependency, regressed metric, missing signature — the pipeline would
> have aborted automatically. There is no `kubectl apply` from a laptop
> in this entire flow. **The git history is the deployment history.**"

---

## Recovery commands (if something goes wrong mid-demo)

### "ArgoCD shows Syncing for >5 min — multi-source race"

```bash
HEAD=$(git rev-parse origin/main)
kubectl --context nonprod -n argocd patch app dev-auth-svc --type=merge \
  -p "{\"operation\":{\"sync\":{\"revision\":\"$HEAD\",\"prune\":true}}}"
```

### "Pod stuck 0/1 with `db` 503 in logs"

The pod's IAM auth token expired. Delete the pod, the RS recreates with a fresh token:
```bash
kubectl --context nonprod -n dev delete pod <pod-name>
```

(Permanent fix already merged — happens only if you forgot to push the
IAM token refresh fix from a previous session.)

### "promote-uat fails with `MANIFEST_UNKNOWN`"

The workflow expects qa overlay's `git-<sha12>` images to exist in ECR.
If you didn't actually merge to main (and let auto-bump run) before
tagging, the qa overlay still points at an image tag that no CI run
produced. Fix order: merge first, wait for qa overlay to update, THEN tag.

### "Pre-flight pods 0/1 — IAM refresh missing"

```bash
# Force-restart all backend pods so they pick up fresh IAM tokens
kubectl --context nonprod -n dev delete pod \
  -l 'app.kubernetes.io/name in (tasks-svc,notifier-svc)'
sleep 30
kubectl --context nonprod -n dev get pods
```

Buys you 15 minutes of healthy pods (enough for the demo).

---

## Cheat sheet (one-pager you can stick on a second monitor)

```
                                  COMMANDS                              👀 WATCH
0. PRE-FLIGHT     kubectl -n dev get pods           → 8x 1/1 Running   open 6 tabs
                  open browser tabs 1-6

1. CHANGE         git checkout -b demo/YYYYMMDD
                  edit apps/auth-svc/cmd/server/main.go (1 line)
                  git diff --stat                   → 1+ 1-
                  git commit -am "feat(auth-svc): ..."

2. PR             git push -u origin HEAD                              Tab2 GH Actions
                  gh pr create --fill                                  green checks appear
                  gh pr checks --watch              → ~5 min

3. MERGE          gh pr merge --squash --delete-branch
                  git checkout main && git pull                        Tab3 ArgoCD
                  gh run watch                      → bump commit      🟡 → 🔵 → 🟢
                  watch ArgoCD UI                                      Tab4 Grafana Pod
                  watch kubectl logs                → demo-run-1       Tab6 Slack:
                                                                       🟡 Sync started
                                                                       🟢 Deployed

4. DEV→QA         gh workflow run nightly-qa.yaml                      Tab6 Slack:
                  gh run watch                      → 14 sec           🟡 nightly-qa start
                  git pull                                             🟢 QA promoted
                                                                       4x 🟢 qa-* Deployed

5. QA→UAT         git pull                                             Tab6 Slack:
                  git tag v0.1.0-rc.$(date +%H%M)                      🟡 promote→UAT start
                  git push --tags                                      🟢 UAT release deployed
                  gh run watch                      → 25 sec           4x 🟢 uat-* Deployed

5.4 OBSERVABILITY Tab4 → Node Exporter / Nodes      → CPU/Mem/Disk per node
    (optional)    Tab5 → Loki "{namespace=dev}|=..."→ multi-svc logs
                  Grafana sign out                  → no password form
                  edit prometheusrule (>1 threshold)→ 🚨 Slack alert in 5min

6. SUMMARY        for env in dev qa uat; do
                    grep tag gitops/overlays/$env/auth-svc.yaml
                  done                              → all three at same tag
```

Total demo time: **25 min** including narration.
Active typing time: **~12 commands**.
