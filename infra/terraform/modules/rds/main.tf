data "aws_caller_identity" "current" {}

resource "aws_kms_key" "rds" {
  description             = "${var.identifier} RDS encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.identifier}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_db_subnet_group" "this" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "rds" {
  name        = "${var.identifier}-rds"
  description = "Postgres ingress from EKS nodes"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "rds_ingress_from_nodes" {
  for_each = toset(var.allowed_security_group_ids)

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = each.value
  security_group_id        = aws_security_group.rds.id
  description              = "Postgres from ${each.value}"
}

resource "aws_db_parameter_group" "pg16" {
  name   = "${var.identifier}-pg16"
  family = "postgres16"

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500" # ms
  }

  # Required for pg_repack and online schema tooling.
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "master" {
  name                    = "${var.identifier}/rds/master"
  kms_key_id              = aws_kms_key.rds.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    database = var.initial_database
  })
}

resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  username = var.master_username
  password = random_password.master.result

  db_name              = var.initial_database
  parameter_group_name = aws_db_parameter_group.pg16.name
  db_subnet_group_name = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az                            = var.multi_az
  publicly_accessible                 = false
  iam_database_authentication_enabled = true

  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:30-mon:05:30"
  copy_tags_to_snapshot   = true

  deletion_protection      = var.deletion_protection
  delete_automated_backups = false

  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.rds.arn

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  apply_immediately = false
  skip_final_snapshot = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.identifier}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}" : null

  lifecycle {
    ignore_changes = [
      final_snapshot_identifier, # rotates with timestamp
      password,                  # if rotated outside TF
    ]
  }
}
