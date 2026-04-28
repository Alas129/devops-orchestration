output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "terraform_role_arn" {
  description = "Role assumed by terraform-apply.yaml on main branch"
  value       = aws_iam_role.terraform.arn
}

output "terraform_plan_role_arn" {
  description = "Read-only role assumed by terraform-plan.yaml on PRs"
  value       = aws_iam_role.terraform_plan.arn
}

output "ecr_push_role_arn" {
  description = "Role assumed by per-service CI workflows for ECR push"
  value       = aws_iam_role.ecr_push.arn
}
