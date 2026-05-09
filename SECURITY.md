# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Email **security@usfdevops.example.com** with:

- Affected component (service / chart / module / workflow)
- Reproduction steps or PoC
- Impact assessment (confidentiality / integrity / availability)
- Suggested mitigation, if any

PGP key for sensitive disclosures: published at
`https://usfdevops.example.com/.well-known/security.txt`.

## Response targets

| Severity | First response | Fix target           |
|----------|----------------|----------------------|
| Critical | < 24h          | Patch within 7 days  |
| High     | < 48h          | Patch within 14 days |
| Medium   | < 5 business d | Next release window  |
| Low      | < 10 business d| Best effort          |

## Scope

In scope:

- Source under `apps/`
- Helm charts under `charts/`
- Terraform modules and env compositions under `infra/terraform/`
- GitHub Actions workflows under `.github/workflows/`
- ArgoCD configuration under `gitops/`

Out of scope:

- Third-party dependencies (please report upstream; we will track via Dependabot)
- Issues that require already-compromised AWS / GitHub credentials
- DoS via excessive request volume against shared dev/qa environments

## Supported versions

Only the `main` branch and the latest `vX.Y.Z` GitHub release receive security
patches. Older tags are not maintained.

## Hardening baseline

The platform enforces:

- OIDC-only AWS access from CI (no static AWS keys)
- Cosign keyless image signatures + SBOM on every image
- Trivy vulnerability scan blocks the build on HIGH/CRITICAL with fixes
- IaC scanning (tfsec) and Kubernetes manifest validation (kubeconform) on PRs
- ArgoCD pull-based delivery — the cluster is never given write-back to AWS
- Per-environment IRSA roles, NetworkPolicy isolation, and seccomp/runAsNonRoot
  on every workload

See `ARCHITECTURE.md` and `RUNBOOK.md` for the full description.
