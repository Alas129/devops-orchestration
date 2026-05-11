output "vault_arn" {
  value = aws_backup_vault.this.arn
}

output "vault_name" {
  value = aws_backup_vault.this.name
}

output "plan_arn" {
  value = aws_backup_plan.this.arn
}

output "kms_key_arn" {
  value = aws_kms_key.backup.arn
}
