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

## CI gating before AWS bootstrap

Before the AWS bootstrap has been applied, several workflows would fail
with "credentials not configured" because their secrets/state-backend do
not yet exist. To avoid red Xs on every push during initial setup, those
workflows are gated on a single repo Variable:

```
Repo → Settings → Secrets and variables → Actions → Variables tab
  Name:  AWS_BOOTSTRAPPED
  Value: true     (set this once bootstrap is done)
```

While `AWS_BOOTSTRAPPED` is unset / not equal to `'true'`:

| Workflow                          | Behaviour                                     |
|-----------------------------------|-----------------------------------------------|
| `terraform-plan` static-checks    | runs (tflint/tfsec/checkov, fmt-check)        |
| `terraform-plan` plan             | **skipped**                                   |
| `terraform-apply`                 | **skipped**                                   |
| `promote-uat` / `promote-prod`    | **skipped** (cosign verify needs ECR)         |
| `ci-<service>` quality            | runs (vet/sast/test)                          |
| `ci-<service>` build-push         | **skipped** (needs ECR + cosign)              |
| `chart-validate`                  | runs                                          |
| `codeql` / `gitleaks` / `dep-rev` | runs                                          |
| `release-please`                  | runs                                          |
| `nightly-qa`                      | runs (only edits files + git push)            |

### Bootstrap sequence (once, locally)

```sh
# 1. State backend (creates S3 bucket + DynamoDB lock table)
cd infra/terraform/bootstrap
terraform init && terraform apply
TF_STATE_BUCKET=$(terraform output -raw state_bucket)

# 2. _shared (Route53, ECR, GitHub OIDC trust, security-baseline)
cd ../envs/_shared
echo "domain_name = \"<your-domain>\"" > terraform.tfvars
terraform init -backend-config="bucket=$TF_STATE_BUCKET" \
               -backend-config="region=us-east-1" \
               -backend-config="dynamodb_table=usf-devops-tflock"
terraform apply
ECR_REGISTRY=$(terraform output -json ecr_repository_urls | jq -r '. | first(.[]) | sub("/[^/]+$";"")')
TF_PLAN_ROLE_ARN=$(terraform output -raw gha_terraform_plan_role_arn)
TF_APPLY_ROLE_ARN=$(terraform output -raw gha_terraform_role_arn)
ECR_PUSH_ROLE_ARN=$(terraform output -raw gha_ecr_push_role_arn)

# 3. Configure repo Settings (Secrets and variables → Actions):
#   Variables:
#     AWS_BOOTSTRAPPED  = true
#     TF_STATE_BUCKET   = $TF_STATE_BUCKET
#     ECR_REGISTRY      = $ECR_REGISTRY
#     DOMAIN_NAME       = <your-domain>
#   Secrets:
#     AWS_ROLE_TF_PLAN  = $TF_PLAN_ROLE_ARN
#     AWS_ROLE_TF_APPLY = $TF_APPLY_ROLE_ARN
#     AWS_ROLE_ECR_PUSH = $ECR_PUSH_ROLE_ARN
#     GITOPS_BOT_TOKEN  = <PAT with repo:write>
#
# 4. Create Environments _shared / nonprod / prod / prod-promote in repo
#    Settings → Environments. Add required reviewers on prod and prod-promote.

# 5. After all of the above, push any change to main and the apply workflow
#    will pick it up and provision nonprod / prod via plan-then-apply.
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
