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

# ── ExternalDNS ────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "external_dns" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }
  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name   = "${var.cluster_name}-external-dns"
  policy = data.aws_iam_policy_document.external_dns.json
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name        = "${var.cluster_name}-external-dns"
  role_policy_arns = { policy = aws_iam_policy.external_dns.arn }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

resource "helm_release" "external_dns" {
  namespace  = "kube-system"
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  wait       = true

  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.external_dns_irsa.iam_role_arn
      }
    }
    provider = "aws"
    aws = {
      region = var.region
      zoneType = "public"
    }
    domainFilters = var.external_dns_domain_filters
    txtOwnerId    = var.cluster_name
    policy        = "sync" # so deleting an Ingress removes the DNS record
    sources = ["service", "ingress"]
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
