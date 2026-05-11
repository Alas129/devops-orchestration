locals {
  cluster_name       = "${var.project}-prod"
  shared             = data.terraform_remote_state.shared.outputs
  domain_name        = local.shared.domain_name
  cloudflare_zone_id = local.shared.cloudflare_zone_id
}

data "aws_caller_identity" "current" {}

# ── Network (separate VPC, NAT per AZ) ─────────────────────────────────────
module "vpc" {
  source             = "../../modules/vpc"
  project            = var.project
  env                = "prod"
  vpc_cidr           = var.vpc_cidr
  single_nat_gateway = false
  cluster_name       = local.cluster_name
}

# ── EKS ────────────────────────────────────────────────────────────────────
module "eks" {
  source             = "../../modules/eks"
  cluster_name       = local.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets
  intra_subnet_ids   = module.vpc.intra_subnets

  # Public endpoint disabled by default in prod; CI assumes the role through a
  # self-hosted runner inside the VPC (or set var.eks_public_access_cidrs to a
  # narrow list of office/VPN egress IPs to reopen).
  cluster_endpoint_public_access = var.eks_public_access_enabled
  public_access_cidrs            = var.eks_public_access_cidrs
  log_retention_days             = 365
}

# ── ALB access logs (referenced by Ingress annotations) ───────────────────
module "alb_logs" {
  source         = "../../modules/alb-logs"
  bucket_name    = "${var.project}-alb-logs-prod-${data.aws_caller_identity.current.account_id}"
  retention_days = 365
}

# ── WAFv2 in front of the ALBs (prod only) ────────────────────────────────
module "waf" {
  source              = "../../modules/waf"
  name                = "${local.cluster_name}-alb"
  rate_limit_per_5min = 2000
  enable_logging      = true
  log_retention_days  = 30
}

module "karpenter" {
  source            = "../../modules/karpenter"
  project           = var.project
  cluster_name      = module.eks.cluster_name
  cluster_version   = module.eks.cluster_version
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  allow_spot        = false # prod stays on-demand
  cpu_limit         = "400"
  memory_limit      = "800Gi"
}

# ── RDS Multi-AZ ───────────────────────────────────────────────────────────
module "rds" {
  source                     = "../../modules/rds"
  identifier                 = "${var.project}-prod"
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnets
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = "db.t4g.medium"
  multi_az                   = true
  deletion_protection        = true
  backup_retention_period    = 30
  monitoring_interval        = 60
  initial_database           = "postgres"
}

# ── AWS Backup vault — extra layer on top of RDS automated backups ────────
# Why both? RDS automated backup is in-region only. AWS Backup gives us
# vault lock, plan-managed retention, and (when configured) cross-region
# copy for true DR.
module "backup" {
  source                  = "../../modules/backup"
  name                    = local.cluster_name
  rds_arns                = [module.rds.arn]
  schedule                = "cron(0 5 ? * * *)"
  cold_storage_after_days = 7
  delete_after_days       = 30
  enable_vault_lock       = false # flip to true after first successful backup
}

# DB role + database NOT managed here — see gitops/platform/db-bootstrap/.
# The Terraform postgresql provider can't reach private-subnet RDS from a
# GHA runner outside the VPC. K8s Job inside the cluster handles it.

# ── ACM (prod + apex-shortcut aliases) ─────────────────────────────────────
# Cert covers prod.<apex> + *.prod.<apex> + the apex-shortcut names so the
# prod Grafana/ArgoCD also serve under argocd.<apex> and grafana.<apex>.
# Justification: prod is the default URL muscle-memory; long-form is alias.
module "acm_prod" {
  source  = "../../modules/acm"
  fqdn    = "prod.${local.domain_name}"
  zone_id = local.cloudflare_zone_id
  additional_sans = [
    "argocd.${local.domain_name}",
    "grafana.${local.domain_name}",
  ]
}

# ── Platform layer ─────────────────────────────────────────────────────────
module "platform" {
  source               = "../../modules/platform-bootstrap"
  cluster_name         = module.eks.cluster_name
  region               = var.region
  vpc_id               = module.vpc.vpc_id
  oidc_provider_arn    = module.eks.oidc_provider_arn
  cloudflare_api_token = var.cloudflare_api_token
  # Filter is the APEX zone name (Cloudflare zone name), not subdomain.
  external_dns_domain_filters = [local.domain_name]
  nats_replicas               = 3 # 3-replica JetStream cluster for prod

  depends_on = [module.karpenter]
}

# ── ArgoCD ─────────────────────────────────────────────────────────────────
module "argocd" {
  source           = "../../modules/argocd-bootstrap"
  subdomain        = "prod"
  domain_name      = local.domain_name
  certificate_arn  = module.acm_prod.certificate_arn
  gitops_repo_url  = "https://github.com/${var.repository}.git"
  gitops_revision  = "main"
  cluster_app_dir  = "prod"
  admin_github_org = split("/", var.repository)[0]
  # Apex-shortcut alias: argocd.<apex> also resolves to prod's ArgoCD.
  additional_hostnames = ["argocd.${local.domain_name}"]

  depends_on = [module.platform]
}

# ── Observability ──────────────────────────────────────────────────────────
module "monitoring" {
  source                      = "../../modules/monitoring-bootstrap"
  subdomain                   = "prod"
  domain_name                 = local.domain_name
  certificate_arn             = module.acm_prod.certificate_arn
  grafana_allowed_github_orgs = split("/", var.repository)[0]
  alert_email_from            = "alerts@${local.domain_name}"
  alert_email_to              = "ops@${local.domain_name}"
  # Apex-shortcut alias: grafana.<apex> also resolves to prod's Grafana.
  additional_hostnames = ["grafana.${local.domain_name}"]

  depends_on = [module.platform]
}

# ── Kyverno + cosign verification policy ───────────────────────────────────
# Production-only: only signed images (built by our GitHub Actions OIDC) may
# run in the prod namespace. Blocks unsigned dev pulls.
resource "helm_release" "kyverno" {
  namespace        = "kyverno"
  create_namespace = true
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = "3.2.6"
  wait             = true

  values = [yamlencode({
    admissionController = {
      replicas = 3
      tolerations = [
        { key = "CriticalAddonsOnly", operator = "Exists" }
      ]
    }
  })]

  depends_on = [module.platform]
}

resource "kubectl_manifest" "verify_signed_images" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "verify-cosign-signatures"
      annotations = {
        "policies.kyverno.io/title"       = "Verify cosign signatures"
        "policies.kyverno.io/description" = "Block unsigned images in the prod namespace"
      }
    }
    spec = {
      validationFailureAction = "Enforce"
      background              = false
      webhookTimeoutSeconds   = 30
      failurePolicy           = "Fail"
      rules = [
        {
          name = "verify-cosign-keyless"
          match = {
            any = [
              { resources = { kinds = ["Pod"], namespaces = ["prod"] } },
            ]
          }
          verifyImages = [
            {
              imageReferences = [
                "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/usf-devops/*",
              ]
              attestors = [
                {
                  count = 1
                  entries = [
                    {
                      keyless = {
                        issuer  = var.cosign_oidc_issuer
                        subject = "https://github.com/${var.repository}/.github/workflows/*"
                        rekor = {
                          url = "https://rekor.sigstore.dev"
                        }
                      }
                    },
                  ]
                },
              ]
              required = true
            },
          ]
        },
      ]
    }
  })
}

# ── Per-service IRSA for prod namespace ────────────────────────────────────
locals {
  service_irsa_targets = {
    for svc in var.service_names :
    svc => svc
  }
}

data "aws_iam_policy_document" "rds_connect_prod" {
  for_each = local.service_irsa_targets

  statement {
    effect  = "Allow"
    actions = ["rds-db:connect"]
    resources = [
      "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.resource_id}/app_prod",
    ]
  }
}

module "service_irsa" {
  for_each = local.service_irsa_targets

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name        = "${local.cluster_name}-${each.key}"
  role_policy_arns = {}

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["prod:${each.key}"]
    }
  }
}

resource "aws_iam_role_policy" "service_rds_connect" {
  for_each = local.service_irsa_targets

  name   = "rds-connect"
  role   = module.service_irsa[each.key].iam_role_name
  policy = data.aws_iam_policy_document.rds_connect_prod[each.key].json
}
