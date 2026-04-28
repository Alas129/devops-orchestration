variable "project" {
  type    = string
  default = "usf-devops"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "repository" {
  type    = string
  default = "alusigmi/devops-orchestration"
}

variable "state_bucket" {
  type        = string
  description = "S3 bucket holding Terraform state (from bootstrap output)"
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "envs" {
  type    = list(string)
  default = ["dev", "qa", "uat"]
}

variable "service_names" {
  type    = list(string)
  default = ["auth-svc", "tasks-svc", "notifier-svc"]
}
