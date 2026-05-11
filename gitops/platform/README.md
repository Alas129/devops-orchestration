# Platform components (ArgoCD-managed)

Each subdirectory holds the Helm values for one platform component. ArgoCD
syncs them via the `nonprod-platform` / `prod-platform` ApplicationSets in
`gitops/argocd/platform/`. Bumping a chart version or tuning a value is a
PR against this directory, then visible in the ArgoCD UI when synced.

| Component | Chart | Why |
|---|---|---|
| `karpenter` | oci://public.ecr.aws/karpenter/karpenter | Worker node provisioning + AMI drift |
| `aws-load-balancer-controller` | aws/eks-charts | ALB Ingress controller |
| `external-dns` | kubernetes-sigs/external-dns | Auto-creates Cloudflare DNS records from Ingress |
| `external-secrets` | external-secrets/external-secrets | SSM Parameter Store → K8s Secret bridge |
| `metrics-server` | kubernetes-sigs/metrics-server | HPA + `kubectl top` |
| `argo-rollouts` | argoproj/argo-rollouts | Canary + blue/green controller |
| `kube-prometheus-stack` | prometheus-community | Prom + Grafana + Alertmanager |
| `loki` | grafana/loki | Log aggregation |
| `tempo` | grafana/tempo | Distributed tracing backend |
| `nats` | nats-io/nats | Event bus |
| `kyverno` | kyverno/kyverno | Admission policies (prod only) |
| `argocd-notifications` | argoproj/argocd-notifications | Slack alerts on sync failure |

## How IRSA role ARNs flow in

Terraform creates the IAM/IRSA roles (in `modules/platform-bootstrap/`) and
writes their ARNs into a single ConfigMap `platform-iam-config` in the
`argocd` namespace. Each platform Application reads from that ConfigMap
via Helm `valueFrom: configMapKeyRef` to wire the right role onto its
ServiceAccount. Single, auditable bridge between Terraform and ArgoCD.

## Bumping a chart

```sh
# 1. Edit gitops/platform/<component>/values.yaml (set new chart version)
# 2. PR
# 3. Merge to main
# 4. ArgoCD UI → platform-<component> → OutOfSync → Sync (or wait for auto-sync)
```

No more `terraform-apply` for platform changes. Live diff visible in UI.
