module "route53" {
  source      = "../../modules/route53"
  domain_name = var.domain_name
}

module "ecr" {
  source       = "../../modules/ecr"
  project      = var.project
  repositories = var.service_names
}

module "github_oidc" {
  source     = "../../modules/github-oidc"
  project    = var.project
  repository = var.repository

  ecr_repository_arns = [for arn in values(module.ecr.repository_arns) : arn]
}
