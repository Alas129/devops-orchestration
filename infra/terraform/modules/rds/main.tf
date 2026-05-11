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
  # count, not for_each: the SG IDs come from `module.eks.node_security_group_id`
  # which is "known after apply" on first creation. for_each requires keys
  # known at plan time; count just needs the LENGTH which we know.
  count = length(var.allowed_security_group_ids)

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = var.allowed_security_group_ids[count.index]
  security_group_id        = aws_security_group.rds.id
  description              = "Postgres from EKS node SG #${count.index}"
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

  # pg_stat_statements for query analysis; pgaudit for compliance-grade
  # session/object auditing. apply_method=pending-reboot because changing
  # shared_preload_libraries requires a restart.
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pgaudit"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "pgaudit.log"
    value = "ddl,role,write"
  }

  parameter {
    name  = "pgaudit.log_catalog"
    value = "off"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

# Enhanced Monitoring IAM role — RDS writes per-second OS metrics into CW.
resource "aws_iam_role" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0
  name  = "${var.identifier}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = var.monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
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

  db_name                = var.initial_database
  parameter_group_name   = aws_db_parameter_group.pg16.name
  db_subnet_group_name   = aws_db_subnet_group.this.name
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

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true

  apply_immediately         = false
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.identifier}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}" : null

  lifecycle {
    ignore_changes = [
      final_snapshot_identifier, # rotates with timestamp
      password,                  # if rotated outside TF
    ]
  }
}
