module "route53" {
  source      = "../../modules/route53"
  domain_name = var.domain_name
}

module "ecr" {
  source                          = "../../modules/ecr"
  project                         = var.project
  repositories                    = var.service_names
  replication_destination_regions = var.ecr_replication_regions
}

module "github_oidc" {
  source     = "../../modules/github-oidc"
  project    = var.project
  repository = var.repository

  ecr_repository_arns = [for arn in values(module.ecr.repository_arns) : arn]
}

module "security_baseline" {
  source  = "../../modules/security-baseline"
  project = var.project
  region  = var.region

  enable_guardduty    = var.enable_guardduty
  enable_security_hub = var.enable_security_hub
  enable_aws_config   = var.enable_aws_config
  enable_cloudtrail   = var.enable_cloudtrail
}
