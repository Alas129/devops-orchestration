variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "hosted_zone_id" {
  type = string
}

variable "external_dns_domain_filters" {
  type        = list(string)
  description = "DNS domains ExternalDNS is allowed to manage (e.g. ['dev.example.com', 'qa.example.com'])"
}

variable "lb_controller_chart_version" {
  type    = string
  default = "1.8.4"
}

variable "external_dns_chart_version" {
  type    = string
  default = "1.15.0"
}

variable "metrics_server_chart_version" {
  type    = string
  default = "3.12.1"
}

variable "argo_rollouts_chart_version" {
  type    = string
  default = "2.37.5"
}

variable "external_secrets_chart_version" {
  type    = string
  default = "0.10.4"
}

variable "nats_chart_version" {
  type    = string
  default = "1.2.6"
}

variable "nats_replicas" {
  type        = number
  default     = 1
  description = "1 in nonprod, 3 in prod"
}
