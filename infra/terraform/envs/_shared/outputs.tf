output "hosted_zone_id" {
  description = "Route53 hosted zone ID, consumed by env modules for ACM + ExternalDNS"
  value       = module.route53.zone_id
}

output "domain_name" {
  description = "Apex domain"
  value       = module.route53.name
}

output "ecr_repository_urls" {
  description = "Map of service name → ECR URI"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  value = module.ecr.repository_arns
}

output "gha_terraform_role_arn" {
  value = module.github_oidc.terraform_role_arn
}

output "gha_terraform_plan_role_arn" {
  value = module.github_oidc.terraform_plan_role_arn
}

output "gha_ecr_push_role_arn" {
  value = module.github_oidc.ecr_push_role_arn
}
