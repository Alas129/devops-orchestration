variable "project" {
  type        = string
  description = "Project prefix"
}

variable "env" {
  type        = string
  description = "Environment slug (e.g. 'nonprod', 'prod')"
}

variable "vpc_cidr" {
  type        = string
  description = "/16 CIDR for the VPC"
}

variable "az_count" {
  type        = number
  default     = 3
  description = "Number of AZs to span"
}

variable "single_nat_gateway" {
  type        = bool
  default     = false
  description = "true = one NAT for all AZs (cheap, lower availability). false = NAT per AZ."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used for subnet tagging so the LB Controller and Karpenter can discover subnets"
}
