variable "identifier" {
  type        = string
  description = "Unique RDS identifier (becomes the instance name)"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets for the DB subnet group (private)"
}

variable "allowed_security_group_ids" {
  type        = list(string)
  description = "SG IDs allowed to reach Postgres on 5432 (typically EKS node SG)"
}

variable "engine_version" {
  type    = string
  default = "16.4"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type        = number
  default     = 100
  description = "Storage autoscaling cap"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "master_username" {
  type    = string
  default = "dbadmin"
}

variable "initial_database" {
  type        = string
  description = "Database created at instance bootstrap (logical DBs are created via postgresql provider afterwards)"
  default     = "postgres"
}
