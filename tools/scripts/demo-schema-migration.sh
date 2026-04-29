#!/usr/bin/env bash
# Walk through the three-step expand→migrate→contract migration demo.
# Doesn't actually touch the cluster; prints the sequence of commits to make.
set -euo pipefail

cat <<'TXT'
Three-step "rename tasks.title → tasks.name" demo

Each release is independently deployable + rollback-safe.
Run k6 in the background throughout to prove zero dropped requests.

────────────────────────────────────────────────────────────
Step 1 — EXPAND  (release v1.2.0)
────────────────────────────────────────────────────────────
Add migration:
  apps/tasks-svc/migrations/0002_expand_name.up.sql
    ALTER TABLE tasks ADD COLUMN IF NOT EXISTS name TEXT;
    UPDATE tasks SET name = title WHERE name IS NULL;
  apps/tasks-svc/migrations/0002_expand_name.down.sql
    ALTER TABLE tasks DROP COLUMN IF EXISTS name;

Update tasks-svc handler.go to write `name` AND `title`.

Commit:  feat(tasks-svc): expand schema for tasks.name (rename phase 1)
Merge   release PR with prerelease=true → tag v1.2.0-rc.1 (deploys to UAT)
Merge   release PR non-prerelease         → tag v1.2.0       (deploys to PROD)

────────────────────────────────────────────────────────────
Step 2 — MIGRATE READERS  (release v1.3.0)
────────────────────────────────────────────────────────────
No migration this release — code-only.

Update tasks-svc handler.go: read `name` first, fall back to `title`.
Still dual-write.

Commit:  feat(tasks-svc): read tasks.name (rename phase 2)
Same release flow as above.

────────────────────────────────────────────────────────────
Step 3 — CONTRACT  (release v1.4.0)
────────────────────────────────────────────────────────────
Add migration:
  apps/tasks-svc/migrations/0003_contract_title.up.sql
    ALTER TABLE tasks DROP COLUMN IF EXISTS title;
  apps/tasks-svc/migrations/0003_contract_title.down.sql
    ALTER TABLE tasks ADD COLUMN title TEXT;
    UPDATE tasks SET title = name;

Update tasks-svc handler.go: write only `name`.

Commit:  feat(tasks-svc): contract schema, drop tasks.title (rename phase 3)
Same release flow.

────────────────────────────────────────────────────────────
Verification (per release)
────────────────────────────────────────────────────────────
  argocd app sync prod-tasks-svc
  kubectl argo rollouts get rollout tasks-svc -n prod    # canary progress
  psql ...                                                # show schema
  cat /tmp/k6.out | grep http_req_failed                  # 0.00%
TXT
