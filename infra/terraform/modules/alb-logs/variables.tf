variable "bucket_name" {
  type        = string
  description = "S3 bucket name. Must be globally unique. e.g. usf-devops-alb-logs-prod-<account>"
}

variable "retention_days" {
  type    = number
  default = 365
}
