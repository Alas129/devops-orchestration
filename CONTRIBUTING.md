# Contributing

## TL;DR

1. Branch from `main`. Use Conventional Commits.
2. Open a PR; CODEOWNERS auto-assigns reviewers.
3. CI must be green: tests, IaC scan (tfsec), manifest validation (kubeconform),
   Trivy image scan, and Cosign signing.
4. release-please opens a release PR automatically; merging it tags + deploys.

## Branch and commit conventions

- Trunk: `main`. All work merges via PR. Direct pushes are blocked by
  branch protection.
- Conventional Commits drive SemVer:
  - `feat(scope): …`     → minor bump
  - `fix(scope): …`      → patch bump
  - `feat(scope)!: …` or `BREAKING CHANGE:` footer → major bump
  - `chore`, `docs`, `test`, `ci`, `refactor` → no version bump
- Scope is the directory name (`auth-svc`, `tasks-svc`, `notifier-svc`,
  `frontend`, `infra`, `charts`, `gitops`).

## Required PR checks

All checks must pass before merge:

| Check                              | What it does                              |
|------------------------------------|-------------------------------------------|
| `ci-<service>`                     | go vet, tests with `-race`, build, push   |
| `terraform-plan`                   | `tf fmt`, `tf validate`, `tf plan`, tfsec |
| `chart-validate`                   | `helm lint --strict`, `kubeconform`       |
| Trivy (HIGH/CRITICAL, fixed only)  | container CVE scan                        |
| Cosign sign                        | keyless image signing                     |

## Required branch protection on `main`

Configure once in repo Settings → Branches → `main`:

- Require pull request reviews (≥ 1 from CODEOWNERS)
- Require status checks: all CI jobs above
- Require signed commits
- Require linear history
- Restrict who can push (only `gitops-bot` for overlay bumps)
- Block force-push and deletion

`promote-prod.yaml` and `terraform-apply.yaml` additionally use a GitHub
**environment** with required reviewers — production cannot deploy
without explicit approval.

## Local quickstart

```sh
make help                     # list all developer targets
make mod-tidy                 # creates go.sum for every Go service
make test                     # runs unit tests (with race detector)
make chart-lint               # helm lint --strict on every chart
make tf-fmt && make tf-validate
```

Optional:

```sh
pip install pre-commit && pre-commit install     # install local hooks
```

## Releasing

1. Merge feature work to `main`. release-please opens a "release-please" PR
   that bumps versions according to commit history.
2. Merge that PR with `prerelease: true` to ship to **uat** (creates
   `vX.Y.Z-rc.N`).
3. After uat soaks, merge a non-prerelease release PR to ship to **prod**
   (creates `vX.Y.Z`). The `promote-prod.yaml` workflow requires manual
   approval in the GitHub `prod` environment.

See `RUNBOOK.md` for promotion mechanics and rollback.

## What lives where

- `apps/<svc>/`         — service source + Dockerfile + migrations
- `charts/<svc>/`       — one Helm chart per workload
- `gitops/overlays/<env>/<svc>.yaml` — per-env Helm values bumped by CI
- `infra/terraform/`    — modules + env compositions (`bootstrap`, `_shared`,
  `nonprod`, `prod`)

Schema changes follow **expand → migrate readers → contract** across three
releases. See `RUNBOOK.md §3`.
