output "endpoint" {
  value = aws_db_instance.this.endpoint
}

output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "instance_id" {
  value = aws_db_instance.this.id
}

output "resource_id" {
  description = "Stable DB resource ID, used in IAM policies for rds-db:connect"
  value       = aws_db_instance.this.resource_id
}

output "security_group_id" {
  value = aws_security_group.rds.id
}

output "kms_key_arn" {
  value = aws_kms_key.rds.arn
}

output "master_secret_arn" {
  value = aws_secretsmanager_secret.master.arn
}

output "master_password" {
  description = "Master password (sensitive). Used by the postgresql provider in env composition."
  value       = random_password.master.result
  sensitive   = true
}

output "master_username" {
  value = var.master_username
}

output "initial_database" {
  value = var.initial_database
}
