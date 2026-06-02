# Tear down the `nonprod` environment

Brings the whole `usf-devops-nonprod` EKS environment to zero on AWS while
preserving `_shared` (ECR, GuardDuty/Config/CloudTrail, GitHub OIDC) and
the Terraform state backend (`usf-devops-tfstate-<account>` S3 bucket).

The companion script `teardown-nonprod.sh` performs the same steps
non-interactively. This file exists so a future operator (or future-you)
understands **why** each phase runs in this order and what to watch for
when something hangs.

## Scope

| Layer                                              | Action            |
| -------------------------------------------------- | ----------------- |
| EKS cluster `usf-devops-nonprod`                   | destroy           |
| RDS `usf-devops-nonprod` (deletion protection on)  | destroy (no snap) |
| VPC / NAT / subnets                                | destroy           |
| ACM certs (dev/qa/uat + cluster wildcard)          | destroy           |
| IRSA roles (service × env, ai-bot)                 | destroy           |
| ALBs created by Ingresses (out-of-band)            | manual drain      |
| EBS volumes from PVCs (Prometheus, Loki)           | manual drain      |
| Karpenter-launched EC2 instances                   | manual drain      |
| SSM `/devops/*` params                             | manual delete     |
| Secrets Manager `usf-devops-nonprod/rds/master`    | manual delete     |
| CloudWatch log groups for the cluster              | manual delete     |
| Cloudflare `*.nonprod.<domain>` and per-env hosts  | TF destroy        |
| Apex domain `calmloop.space` registration          | **kept**          |
| Cloudflare zone                                    | **kept**          |
| Terraform state bucket + DynamoDB lock table       | **kept**          |
| `_shared` env (ECR, OIDC, GuardDuty etc.)          | **kept**          |
| `prod` env (separate decision)                     | **kept**          |

## Why this order

The naive answer — `terraform destroy` and walk away — does not work here
because Terraform does not own three classes of resources that live inside
the cluster:

1. **ALBs** are created by the AWS Load Balancer Controller in response to
   `Ingress` objects. If you delete the cluster while Ingresses still
   exist, the ALBs and their target groups leak. ENIs also leak and block
   subnet deletion.
2. **EBS volumes** are dynamically provisioned by the EBS CSI driver in
   response to `PersistentVolumeClaim`s (Prometheus 50Gi, Loki 100Gi,
   Grafana 10Gi). Same problem — they outlive the cluster.
3. **EC2 nodes** are launched by Karpenter, not by an ASG that Terraform
   knows about. Destroying the EKS control plane leaves these nodes
   running and accruing cost until you find them by tag.

The script drains these first, then runs `terraform destroy` in two passes
(K8s-side resources before AWS-side resources, so the kubernetes/helm
providers still have a live API server to talk to).

## Phases

### 0. Preflight

- Verify AWS identity = `164856787183` and region = `us-east-1`.
- Update kubeconfig and confirm the cluster responds.
- Print a one-line cost summary so you remember what you are about to delete.

### 1. Quiet ArgoCD

ArgoCD will self-heal anything we delete. Scale its controllers to zero
**before** deleting any of its child resources:

```sh
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
kubectl -n argocd scale deploy argocd-applicationset-controller argocd-repo-server argocd-server argocd-redis --replicas=0
```

Do **not** `kubectl delete application --all` first — ArgoCD honors the
`resources-finalizer.argoproj.io` finalizer and will try to clean up the
managed resources gracefully, which races with the steps below.

### 2. Drain Ingresses, Services, PVCs

For each app namespace (`dev qa uat argocd monitoring ai-bot`):

```sh
kubectl -n "$ns" delete ingress --all --wait=false
kubectl -n "$ns" delete svc -l 'app!=' --field-selector spec.type=LoadBalancer
kubectl -n "$ns" delete pvc --all --wait=false
```

Then poll until the AWS Load Balancer Controller is done:

```sh
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s')].LoadBalancerArn"
```

When this returns `[]` the ALBs are gone. Usually 60–120s.

### 3. Stop Karpenter, drain nodes

```sh
kubectl delete nodepool --all --wait=false
kubectl delete ec2nodeclass --all --wait=false
kubectl delete nodeclaim --all --wait=false
```

Wait for `kubectl get nodes` to show only the EKS-managed system node (if
any) or nothing.

### 4. Terraform destroy — pass 1 (K8s-resident modules)

These three modules use the kubernetes / helm providers and need a live
EKS API server. Destroy them while the cluster is still up:

```sh
cd infra/terraform/envs/nonprod
terraform destroy -auto-approve -var-file=terraform.tfvars \
  -target=module.argocd \
  -target=module.monitoring \
  -target=module.platform
```

### 5. Terraform destroy — pass 2 (everything else)

```sh
terraform destroy -auto-approve -var-file=terraform.tfvars \
  -var deletion_protection=false
```

The `-var deletion_protection=false` does two things in our RDS module:

- flips `deletion_protection` on the DB instance to `false`
- flips `skip_final_snapshot` to `true`

so the destroy actually completes instead of refusing to delete the DB.
If you want a final snapshot, remove that var, delete the RDS manually
with `--final-db-snapshot-identifier`, then re-run destroy.

### 6. Manual cleanup (resources not in TF state)

```sh
# SSM parameters
aws ssm delete-parameter --name /devops/alertmanager/slack_webhook_url
aws ssm delete-parameter --name /devops/grafana/github/client_secret

# Secrets Manager — RDS master secret (force, no recovery window)
aws secretsmanager delete-secret \
  --secret-id usf-devops-nonprod/rds/master \
  --force-delete-without-recovery 2>/dev/null || true

# CloudWatch log groups for the cluster + RDS + Karpenter
for lg in \
  /aws/eks/usf-devops-nonprod/cluster \
  /aws/rds/instance/usf-devops-nonprod/postgresql \
  /aws/karpenter/usf-devops-nonprod ; do
  aws logs delete-log-group --log-group-name "$lg" 2>/dev/null || true
done

# Orphan ENIs (load-balancer-controller leftovers)
aws ec2 describe-network-interfaces \
  --filters Name=description,Values='*usf-devops-nonprod*' \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text \
  | xargs -n1 -I{} aws ec2 delete-network-interface --network-interface-id {}

# Orphan EBS volumes (Available, tagged with the cluster)
aws ec2 describe-volumes \
  --filters Name=status,Values=available \
            Name=tag:kubernetes.io/cluster/usf-devops-nonprod,Values=owned \
  --query 'Volumes[].VolumeId' --output text \
  | xargs -n1 -I{} aws ec2 delete-volume --volume-id {}
```

### 7. Verify

```sh
aws eks list-clusters --region us-east-1                                # no usf-devops-nonprod
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'  # no usf-devops-nonprod
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  Name=tag:karpenter.sh/cluster,Values=usf-devops-nonprod                 # empty
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'  # no k8s-*
```

## What survives

- TF state bucket `usf-devops-tfstate-164856787183` (re-applyable)
- `_shared` outputs (ECR repos still hold images, GuardDuty/Config/CloudTrail keep recording)
- `prod` env intact
- Apex zone `calmloop.space` and Cloudflare zone — `*.nonprod.<domain>` records vanish via TF destroy

## Re-apply from clean

```sh
cd infra/terraform/envs/nonprod
terraform init -backend-config="bucket=usf-devops-tfstate-164856787183" \
               -backend-config="region=us-east-1" \
               -backend-config="dynamodb_table=usf-devops-tfstate-lock"
terraform apply -var-file=terraform.tfvars
```

After apply, re-create SSM params:

```sh
aws ssm put-parameter --name /devops/alertmanager/slack_webhook_url \
  --type SecureString --value 'https://hooks.slack.com/...'
aws ssm put-parameter --name /devops/grafana/github/client_secret \
  --type SecureString --value '...'
```

Then push to `main` and ArgoCD will rebuild the workloads.

## Failure modes seen before

- **`terraform destroy` hangs on `module.platform.helm_release.*`** — the
  EKS API server is already gone. Fix: `terraform state rm` those
  resources, then re-run destroy. Helm release records inside the cluster
  do not need to be cleaned (cluster is gone).
- **VPC won't delete because of dependency violations** — orphan ENIs from
  load-balancer-controller. Run the ENI sweep from Phase 6, then re-run
  destroy.
- **RDS refuses to delete** — deletion protection still on. Either re-run
  with `-var deletion_protection=false` or `aws rds modify-db-instance
  --db-instance-identifier usf-devops-nonprod --no-deletion-protection
  --apply-immediately` first.
- **TF state lock won't release** — `terraform force-unlock <lock-id>`.
  Visible in the DynamoDB table `usf-devops-tfstate-lock`.
