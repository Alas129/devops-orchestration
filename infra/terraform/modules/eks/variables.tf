variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "intra_subnet_ids" {
  type        = list(string)
  description = "Subnets for the EKS control plane ENIs (typically intra/private with no NAT route)"
}

variable "public_access_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the public EKS API endpoint. Tighten in prod."
}
