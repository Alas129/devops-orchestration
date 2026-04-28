resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
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
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
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
