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
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16" # different /16 from nonprod (10.10.0.0/16)
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "service_names" {
  type    = list(string)
  default = ["auth-svc", "tasks-svc", "notifier-svc"]
}

variable "cosign_oidc_issuer" {
  type        = string
  description = "OIDC issuer used by cosign keyless signing — GitHub Actions fixed value"
  default     = "https://token.actions.githubusercontent.com"
}

variable "eks_public_access_enabled" {
  type        = bool
  default     = false
  description = "Whether the prod EKS API endpoint is reachable from the public internet. Default closed."
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  default     = []
  description = "If eks_public_access_enabled=true, restrict to these CIDRs (e.g. office VPN egress IPs). Empty = none reachable."
}
