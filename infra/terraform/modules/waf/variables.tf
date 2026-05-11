variable "name" {
  type        = string
  description = "Web ACL name. Will also prefix all CloudWatch metric names."
}

variable "rate_limit_per_5min" {
  type        = number
  default     = 2000
  description = "Requests per source IP per 5-min window before rate-limit blocks."
}

variable "enable_logging" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}
