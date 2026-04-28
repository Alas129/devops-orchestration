output "repository_urls" {
  description = "Map of short name → full ECR URI"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of short name → ECR ARN (used in IAM policies)"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}
