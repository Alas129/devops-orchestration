variable "project" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version, used to pick the matching Bottlerocket AMI"
}

variable "cluster_endpoint" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "karpenter_chart_version" {
  type    = string
  default = "1.0.8"
}

variable "allow_spot" {
  type        = bool
  default     = true
  description = "Allow Karpenter to provision spot capacity. true for nonprod, configurable for prod."
}

variable "cpu_limit" {
  type    = string
  default = "200"
}

variable "memory_limit" {
  type    = string
  default = "400Gi"
}
