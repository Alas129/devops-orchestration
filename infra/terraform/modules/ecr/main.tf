resource "aws_kms_key" "ecr" {
  description             = "${var.project} ECR image encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags = {
    "Name" = "${var.project}-ecr"
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.project}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  # Keep all release tags (v*); for everything else keep the most recent N.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep all v* release tags forever"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 9999
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 7 days (was 14; image churn during digest pinning)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Keep last ${var.retain_count} non-release tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["git-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.retain_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Cross-region replication for DR. The replication target region must already
# have the same repository names; AWS auto-creates the destination repos on
# the first push when registry-level replication is configured.
resource "aws_ecr_replication_configuration" "this" {
  count = length(var.replication_destination_regions) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = var.replication_destination_regions
        content {
          region      = destination.value
          registry_id = data.aws_caller_identity.current.account_id
        }
      }
      repository_filter {
        filter      = "${var.project}/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

data "aws_caller_identity" "current" {}
