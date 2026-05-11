# Cluster-level platform pieces that aren't per-app: ingress controller,
# DNS automation, rollout controller, secret operator, message bus.
# Day-2 patching for these is via Helm chart version bumps in this module.

# ── AWS Load Balancer Controller ───────────────────────────────────────────
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${var.cluster_name}-aws-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_lb_controller" {
  namespace  = "kube-system"
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  wait       = true

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.region
    vpcId       = var.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.lb_controller_irsa.iam_role_arn
      }
    }
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" }
    ]
    nodeSelector = {
      "node-pool" = "bootstrap"
    }
  })]
}

# ── ExternalDNS (Cloudflare provider) ──────────────────────────────────────
# We don't need IRSA because external-dns talks to the Cloudflare API, not to
# AWS. The Cloudflare API token is mounted into the pod as an env var via a
# K8s Secret created here from the var.cloudflare_api_token Terraform value.
#
# The token must be scoped to:
#   - Zone:Zone:Read    (so external-dns can locate the zone)
#   - Zone:DNS:Edit     (so it can create/update/delete records)
# limited to the calmloop.space zone.

resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace.external_dns.metadata[0].name
  }
  data = {
    apiToken = var.cloudflare_api_token
  }
  type = "Opaque"
}

resource "helm_release" "external_dns" {
  namespace  = kubernetes_namespace.external_dns.metadata[0].name
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  wait       = true

  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "external-dns"
    }
    provider = "cloudflare"
    env = [
      {
        name = "CF_API_TOKEN"
        valueFrom = {
          secretKeyRef = {
            name = kubernetes_secret.cloudflare_api_token.metadata[0].name
            key  = "apiToken"
          }
        }
      }
    ]
    domainFilters = var.external_dns_domain_filters
    txtOwnerId    = var.cluster_name
    # `upsert-only` is safer than `sync` while we're proving the pipeline;
    # flip to `sync` once we trust deletes propagate correctly.
    policy  = "upsert-only"
    sources = ["service", "ingress"]
    cloudflare = {
      # gray-cloud by default: records resolve straight to the ALB. Per-record
      # `external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"` flips to
      # orange cloud (Cloudflare CDN/WAF in front).
      proxied = false
    }
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" }
    ]
    nodeSelector = {
      "node-pool" = "bootstrap"
    }
  })]
}

# ── metrics-server ─────────────────────────────────────────────────────────
resource "helm_release" "metrics_server" {
  namespace  = "kube-system"
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  wait       = true

  values = [yamlencode({
    args = ["--kubelet-insecure-tls"] # EKS kubelet certs aren't signed by cluster CA
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" }
    ]
    nodeSelector = {
      "node-pool" = "bootstrap"
    }
  })]
}

# ── Argo Rollouts ──────────────────────────────────────────────────────────
resource "helm_release" "argo_rollouts" {
  namespace        = "argo-rollouts"
  create_namespace = true
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.argo_rollouts_chart_version
  wait             = true

  values = [yamlencode({
    controller = {
      tolerations = [
        { key = "CriticalAddonsOnly", operator = "Exists" }
      ]
      nodeSelector = {
        "node-pool" = "bootstrap"
      }
    }
    dashboard = { enabled = true }
  })]
}

# ── External Secrets Operator (SSM/SecretsManager → K8s Secret) ───────────
data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/devops/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["*"]
  }
  # KMS decrypt is required to read AWS-managed-key encrypted secrets
  # (RDS module writes its master secret with a CMK). Without this the
  # rds-master ExternalSecret fails with "Access to KMS is not allowed".
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["arn:aws:kms:${var.region}:*:key/*"]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name   = "${var.cluster_name}-external-secrets"
  policy = data.aws_iam_policy_document.external_secrets.json
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name        = "${var.cluster_name}-external-secrets"
  role_policy_arns = { policy = aws_iam_policy.external_secrets.arn }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "helm_release" "external_secrets" {
  namespace        = "external-secrets"
  create_namespace = true
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  wait             = true

  values = [yamlencode({
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.external_secrets_irsa.iam_role_arn
      }
    }
  })]
}

# Cluster-wide SecretStore pointing at AWS SSM. Each ExternalSecret in the
# cluster references this by name.
resource "kubectl_manifest" "ssm_cluster_secret_store" {
  depends_on = [helm_release.external_secrets]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "aws-ssm" }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })
}

# Second ClusterSecretStore for AWS Secrets Manager. The RDS module
# stores its master credentials in SecretsManager (encrypted with a CMK),
# and gitops/platform/db-bootstrap pulls them via this store.
resource "kubectl_manifest" "secretsmanager_cluster_secret_store" {
  depends_on = [helm_release.external_secrets]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "aws-secretsmanager" }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })
}

# ── NATS JetStream ─────────────────────────────────────────────────────────
resource "helm_release" "nats" {
  namespace        = "messaging"
  create_namespace = true
  name             = "nats"
  repository       = "https://nats-io.github.io/k8s/helm/charts/"
  chart            = "nats"
  version          = var.nats_chart_version
  wait             = true

  values = [yamlencode({
    config = {
      cluster = {
        enabled  = var.nats_replicas > 1
        replicas = var.nats_replicas
      }
      jetstream = {
        enabled = true
        fileStore = {
          enabled = true
          pvc = {
            enabled = true
            size    = "5Gi"
          }
        }
      }
    }
  })]
}
