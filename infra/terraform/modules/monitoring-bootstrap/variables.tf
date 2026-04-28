variable "kube_prom_chart_version" {
  type    = string
  default = "65.5.1"
}

variable "loki_chart_version" {
  type    = string
  default = "2.10.2"
}

variable "subdomain" {
  type        = string
  description = "Hostname prefix one level below the apex (e.g. 'nonprod' → grafana.nonprod.<domain>)"
}

variable "domain_name" {
  type = string
}

variable "certificate_arn" {
  type        = string
  description = "ACM cert covering grafana.<subdomain>.<domain>"
}

variable "grafana_allowed_github_orgs" {
  type        = string
  description = "Space-separated GitHub orgs whose members can sign in"
}

variable "alert_email_from" {
  type    = string
  default = "alerts@example.com"
}

variable "alert_email_to" {
  type    = string
  default = "ops@example.com"
}

variable "smtp_host" {
  type        = string
  description = "SES SMTP endpoint (e.g. email-smtp.us-east-1.amazonaws.com)"
  default     = "email-smtp.us-east-1.amazonaws.com"
}

variable "smtp_port" {
  type    = number
  default = 587
}

variable "slack_channel" {
  type    = string
  default = "#devops-alerts"
}
