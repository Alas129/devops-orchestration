# GitHub Actions OIDC trust + scoped IAM roles.
#
# Provides three roles:
#   - terraform_role : assumes broad admin in this account, used by terraform-apply.yaml
#                      Restricted to the protected branch (main) of the repo.
#   - terraform_plan_role : read-only, allowed to assume from PRs (pull_request)
#                           so plans can be posted as comments without granting
#                           write access to AWS.
#   - ecr_push_role  : minimal, only ECR push to the project's repos.

data "aws_caller_identity" "current" {}

# ── OIDC provider ──────────────────────────────────────────────────────────
# Thumbprint is hardcoded by AWS docs; verified once. AWS now accepts an
# empty list and will validate against trusted root CAs, but pinning is
# defensive.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  # GitHub OIDC sub claims:
  #   repo:<owner>/<repo>:ref:refs/heads/<branch>
  #   repo:<owner>/<repo>:pull_request
  #   repo:<owner>/<repo>:ref:refs/tags/<tag>
  main_subs = [
    "repo:${var.repository}:ref:refs/heads/main",
    "repo:${var.repository}:ref:refs/tags/v*",
  ]
  pr_subs = [
    "repo:${var.repository}:pull_request",
  ]
}

# ── terraform_role (apply, main branch only) ───────────────────────────────
resource "aws_iam_role" "terraform" {
  name = "${var.project}-gha-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.main_subs
        }
      }
    }]
  })
}

# Pragmatic choice: AdministratorAccess for the Terraform-managed account.
# Terraform managing EKS+VPC+IAM+RDS realistically needs broad permissions;
# the security boundary is "this role is only assumable from main-branch CI".
# Tighter PoLP would mean enumerating ~80 permissions and is brittle.
resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── terraform_plan_role (read-only, PR context) ────────────────────────────
resource "aws_iam_role" "terraform_plan" {
  name = "${var.project}-gha-terraform-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = concat(local.main_subs, local.pr_subs)
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan also needs to write the lock + read state. ReadOnlyAccess covers reads;
# add lock-write so plan can grab the DDB lock.
data "aws_iam_policy_document" "plan_state_write" {
  statement {
    sid    = "StateLockReadWrite"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = ["arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/${var.project}-tflock"]
  }

  statement {
    sid    = "StateBucketReadOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.project}-tfstate-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project}-tfstate-${data.aws_caller_identity.current.account_id}/*",
    ]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "state-lock-rw"
  role   = aws_iam_role.terraform_plan.id
  policy = data.aws_iam_policy_document.plan_state_write.json
}

# ── ecr_push_role (CI build & push) ────────────────────────────────────────
resource "aws_iam_role" "ecr_push" {
  name = "${var.project}-gha-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = concat(local.main_subs, local.pr_subs)
        }
      }
    }]
  })
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
