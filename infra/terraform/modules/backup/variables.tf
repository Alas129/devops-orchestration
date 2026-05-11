variable "name" {
  type        = string
  description = "Vault and plan name prefix (e.g. usf-devops-prod)."
}

variable "rds_arns" {
  type        = list(string)
  description = "RDS instance / cluster ARNs to include in the backup plan."
  default     = []
}

variable "schedule" {
  type        = string
  description = "Backup schedule (cron expression in AWS Backup format)."
  default     = "cron(0 5 ? * * *)" # 05:00 UTC daily
}

variable "cold_storage_after_days" {
  type    = number
  default = 7
}

variable "delete_after_days" {
  type    = number
  default = 30
}

variable "enable_vault_lock" {
  type        = bool
  default     = false
  description = "Enable vault-lock to prevent recovery point deletion (governance mode)."
}
