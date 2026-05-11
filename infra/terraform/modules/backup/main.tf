# AWS Backup vault + plan covering RDS. Cost: $0.05/GB/month for vault
# storage (warm) + $0.01/GB/month after 1 month in cold storage.
# Production target: RPO ≤ 24h, retain 30 days, cold after 7 days.

resource "aws_kms_key" "backup" {
  description             = "${var.name} AWS Backup vault encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.name}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

resource "aws_backup_vault" "this" {
  name        = var.name
  kms_key_arn = aws_kms_key.backup.arn

  # Don't allow accidental deletion of vault while it holds recovery points.
  force_destroy = false
}

# Vault Lock — once enabled and the grace period passes, no IAM principal
# (including root) can delete recovery points before their retention expires.
# Enable in prod via var.enable_vault_lock = true. Plan + governance lock
# below is a "governance" mode (admins can still adjust). Switch to
# "compliance" mode for hard immutability.
resource "aws_backup_vault_lock_configuration" "this" {
  count = var.enable_vault_lock ? 1 : 0

  backup_vault_name   = aws_backup_vault.this.name
  changeable_for_days = 3 # grace period before compliance mode locks in
  min_retention_days  = 7
  max_retention_days  = 365
}

resource "aws_iam_role" "backup" {
  name = "${var.name}-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_plan" "this" {
  name = "${var.name}-plan"

  rule {
    rule_name         = "daily-snapshot"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.schedule # default: cron(0 5 ? * * *) = 05:00 UTC daily

    start_window      = 60  # minutes before backup MUST start
    completion_window = 360 # minutes for backup to complete

    lifecycle {
      cold_storage_after = var.cold_storage_after_days
      delete_after       = var.delete_after_days
    }

    recovery_point_tags = {
      Plan      = "${var.name}-plan"
      ManagedBy = "terraform"
    }
  }
}

resource "aws_backup_selection" "rds" {
  count = length(var.rds_arns) > 0 ? 1 : 0

  iam_role_arn = aws_iam_role.backup.arn
  name         = "${var.name}-rds"
  plan_id      = aws_backup_plan.this.id

  resources = var.rds_arns
}
