variable "project" {
  description = "Project name, used for resource naming"
  type        = string
  default     = "usf-devops"
}

variable "region" {
  description = "AWS region for the state backend"
  type        = string
  default     = "us-east-1"
}

variable "repository" {
  description = "Source repository (org/name) — recorded in default tags"
  type        = string
  default     = "alusigmi/devops-orchestration"
}
