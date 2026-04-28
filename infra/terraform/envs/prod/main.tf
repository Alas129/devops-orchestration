locals {
  cluster_name   = "${var.project}-prod"
  shared         = data.terraform_remote_state.shared.outputs
  domain_name    = local.shared.domain_name
  hosted_zone_id = local.shared.hosted_zone_id
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
  # Tighten in real prod: only the office VPN egress IPs.
  public_access_cidrs = ["0.0.0.0/0"]
}

module "karpenter" {
  source            = "../../modules/karpenter"
  project           = var.project
  cluster_name      = module.eks.cluster_name
  cluster_version   = module.eks.cluster_version
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  allow_spot        = false        # prod stays on-demand
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
  backup_retention_period    = 14
  initial_database           = "postgres"
}

resource "postgresql_role" "prod" {
  name     = "app_prod"
  login    = true
  password = ""
  roles    = ["rds_iam"]
}

resource "postgresql_database" "prod" {
  name              = "devops_prod"
  owner             = postgresql_role.prod.name
  encoding          = "UTF8"
  lc_collate        = "en_US.UTF-8"
  lc_ctype          = "en_US.UTF-8"
  template          = "template0"
  connection_limit  = -1
  allow_connections = true

  depends_on = [postgresql_role.prod]
}

# ── ACM (cluster + per-env certs) ──────────────────────────────────────────
module "acm_prod" {
  source  = "../../modules/acm"
  fqdn    = "prod.${local.domain_name}"
  zone_id = local.hosted_zone_id
}

# ── Platform layer ─────────────────────────────────────────────────────────
module "platform" {
  source            = "../../modules/platform-bootstrap"
  cluster_name      = module.eks.cluster_name
  region            = var.region
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  hosted_zone_id    = local.hosted_zone_id
  external_dns_domain_filters = [
    "prod.${local.domain_name}",
  ]
  nats_replicas = 3                      # 3-replica JetStream cluster for prod

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
          name  = "verify-cosign-keyless"
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
    effect = "Allow"
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
