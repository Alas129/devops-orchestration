variable "argocd_chart_version" {
  type    = string
  default = "7.6.12"
}

variable "subdomain" {
  type        = string
  description = "Sub-prefix for ArgoCD's hostname (e.g. 'nonprod' → argocd.nonprod.<domain>)"
}

variable "domain_name" {
  type = string
}

variable "certificate_arn" {
  type        = string
  description = "ACM cert ARN for the ArgoCD ingress (cert covers *.<subdomain>.<domain>)"
}

variable "gitops_repo_url" {
  type        = string
  description = "https://github.com/<org>/<repo>.git"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "cluster_app_dir" {
  type        = string
  description = "Subdirectory under gitops/argocd/applications/ (e.g. 'nonprod' or 'prod')"
}

variable "admin_github_org" {
  type        = string
  description = "GitHub org name; users in 'org:admins' team get ArgoCD admin"
  default     = "alusigmi"
}
