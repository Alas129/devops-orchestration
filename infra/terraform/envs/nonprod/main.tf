locals {
  cluster_name   = "${var.project}-nonprod"
  shared         = data.terraform_remote_state.shared.outputs
  domain_name    = local.shared.domain_name
  hosted_zone_id = local.shared.hosted_zone_id
}

# ── Network ────────────────────────────────────────────────────────────────
module "vpc" {
  source             = "../../modules/vpc"
  project            = var.project
  env                = "nonprod"
  vpc_cidr           = var.vpc_cidr
  single_nat_gateway = true # cost saver — nonprod has no SLA
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
}

# ── Karpenter (Bottlerocket, spot allowed) ─────────────────────────────────
module "karpenter" {
  source            = "../../modules/karpenter"
  project           = var.project
  cluster_name      = module.eks.cluster_name
  cluster_version   = module.eks.cluster_version
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  allow_spot        = true
}

# ── RDS Postgres (single instance, 3 logical DBs for dev/qa/uat) ───────────
module "rds" {
  source                     = "../../modules/rds"
  identifier                 = "${var.project}-nonprod"
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnets
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = "db.t4g.small"
  multi_az                   = false
  deletion_protection        = false
  backup_retention_period    = 1
  initial_database           = "postgres"
}

# Per-env logical databases + IAM-auth roles.
# Dev/qa/uat are namespaces in the same EKS cluster pointing at separate
# Postgres roles + databases inside the same RDS instance.
resource "postgresql_role" "env" {
  for_each = toset(var.envs)

  name     = "app_${each.key}"
  login    = true
  password = "" # IAM auth — no password
  # The rds_iam role is created by RDS automatically when iam_database_authentication_enabled=true.
  roles    = ["rds_iam"]
}

resource "postgresql_database" "env" {
  for_each = toset(var.envs)

  name              = "devops_${each.key}"
  owner             = postgresql_role.env[each.key].name
  encoding          = "UTF8"
  lc_collate        = "en_US.UTF-8"
  lc_ctype          = "en_US.UTF-8"
  template          = "template0"
  connection_limit  = -1
  allow_connections = true

  depends_on = [postgresql_role.env]
}

# ── ACM wildcard cert per env subdomain ────────────────────────────────────
module "acm_dev" {
  source  = "../../modules/acm"
  fqdn    = "dev.${local.domain_name}"
  zone_id = local.hosted_zone_id
}

module "acm_qa" {
  source  = "../../modules/acm"
  fqdn    = "qa.${local.domain_name}"
  zone_id = local.hosted_zone_id
}

module "acm_uat" {
  source  = "../../modules/acm"
  fqdn    = "uat.${local.domain_name}"
  zone_id = local.hosted_zone_id
}

# Cluster-level cert (Grafana, ArgoCD, etc.). Covers *.nonprod.<domain>.
module "acm_cluster" {
  source  = "../../modules/acm"
  fqdn    = "nonprod.${local.domain_name}"
  zone_id = local.hosted_zone_id
}

# ── Platform layer (LB Controller, ExternalDNS, Argo Rollouts, ESO, NATS) ──
module "platform" {
  source            = "../../modules/platform-bootstrap"
  cluster_name      = module.eks.cluster_name
  region            = var.region
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  hosted_zone_id    = local.hosted_zone_id
  external_dns_domain_filters = [
    "dev.${local.domain_name}",
    "qa.${local.domain_name}",
    "uat.${local.domain_name}",
    "nonprod.${local.domain_name}",
  ]
  nats_replicas = 1

  depends_on = [module.karpenter]
}

# ── ArgoCD ─────────────────────────────────────────────────────────────────
module "argocd" {
  source           = "../../modules/argocd-bootstrap"
  subdomain        = "nonprod"
  domain_name      = local.domain_name
  certificate_arn  = module.acm_cluster.certificate_arn
  gitops_repo_url  = "https://github.com/${var.repository}.git"
  gitops_revision  = "main"
  cluster_app_dir  = "nonprod"
  admin_github_org = split("/", var.repository)[0]

  depends_on = [module.platform]
}

# ── Observability ──────────────────────────────────────────────────────────
module "monitoring" {
  source                      = "../../modules/monitoring-bootstrap"
  subdomain                   = "nonprod"
  domain_name                 = local.domain_name
  certificate_arn             = module.acm_cluster.certificate_arn
  grafana_allowed_github_orgs = split("/", var.repository)[0]
  alert_email_from            = "alerts@${local.domain_name}"
  alert_email_to              = "ops@${local.domain_name}"

  depends_on = [module.platform]
}

# ── IRSA roles for application workloads (RDS IAM auth) ────────────────────
# Each env × service combo gets a role that can `rds-db:connect` as its
# corresponding Postgres role.
locals {
  service_roles = {
    for combo in setproduct(var.envs, var.service_names) :
    "${combo[0]}-${combo[1]}" => {
      env     = combo[0]
      service = combo[1]
    }
  }
}

data "aws_iam_policy_document" "rds_connect" {
  for_each = local.service_roles

  statement {
    effect = "Allow"
    actions = ["rds-db:connect"]
    resources = [
      "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.resource_id}/app_${each.value.env}",
    ]
  }
}

data "aws_caller_identity" "current" {}

module "service_irsa" {
  for_each = local.service_roles

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.cluster_name}-${each.key}"
  role_policy_arns = {}

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${each.value.env}:${each.value.service}"]
    }
  }
}

resource "aws_iam_role_policy" "service_rds_connect" {
  for_each = local.service_roles

  name   = "rds-connect"
  role   = module.service_irsa[each.key].iam_role_name
  policy = data.aws_iam_policy_document.rds_connect[each.key].json
}
