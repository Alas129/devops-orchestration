variable "project" {
  description = "Project name (used as prefix for resource naming)"
  type        = string
  default     = "usf-devops"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "repository" {
  description = "GitHub repo identifier (owner/name)"
  type        = string
  default     = "Alas129/devops-orchestration"
}

variable "domain_name" {
  description = "Apex domain hosted in Cloudflare (e.g. calmloop.space)"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to Zone:Read + Zone:DNS:Edit on the apex zone. Set via TF_VAR_cloudflare_api_token — never commit."
  type        = string
  sensitive   = true
}

variable "service_names" {
  description = "Microservice / app short names (one ECR repo per name)"
  type        = list(string)
  default     = ["frontend", "auth-svc", "tasks-svc", "notifier-svc", "migrate-runner", "ai-bot"]
}

variable "ecr_replication_regions" {
  description = "Regions to mirror ECR images into for DR (empty = no replication)."
  type        = list(string)
  default     = ["us-west-2"]
}

variable "enable_guardduty" {
  type    = bool
  default = true
}

variable "enable_security_hub" {
  type    = bool
  default = true
}

variable "enable_aws_config" {
  type    = bool
  default = true
}

variable "enable_cloudtrail" {
  type    = bool
  default = true
}
