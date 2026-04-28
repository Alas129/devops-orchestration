variable "project" {
  description = "Project prefix for IAM resource naming"
  type        = string
}

variable "repository" {
  description = "GitHub repo identifier in 'owner/name' form (e.g. 'alusigmi/devops-orchestration')"
  type        = string
}

variable "ecr_repository_arns" {
  description = "List of ECR repo ARNs the CI push role is allowed to push to"
  type        = list(string)
}
