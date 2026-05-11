# ai-bot IRSA role: lets the bot's ServiceAccount in the `ai-bot` namespace
# read SSM SecureString parameters (its API keys live in /devops/ai-bot/*)
# and decrypt them via the SSM-scoped KMS condition.
#
# The K8s ClusterRole bound to the same SA gives read-only access to the
# cluster's own resources (pods, rollouts, applications, etc.) — that is
# managed in `charts/ai-bot/templates/clusterrole.yaml`, NOT here. The AWS
# IAM policy only handles AWS-side reads.

module "ai_bot_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name        = "${local.cluster_name}-ai-bot"
  role_policy_arns = {}

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["ai-bot:ai-bot"]
    }
  }
}

data "aws_iam_policy_document" "ai_bot_ssm" {
  statement {
    sid     = "ReadAIBotSSMParameters"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/devops/ai-bot/*",
    ]
  }
  statement {
    sid     = "DecryptSSMSecureString"
    effect  = "Allow"
    actions = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ai_bot_ssm" {
  name   = "ssm-read"
  role   = module.ai_bot_irsa.iam_role_name
  policy = data.aws_iam_policy_document.ai_bot_ssm.json
}

output "ai_bot_irsa_role_arn" {
  value       = module.ai_bot_irsa.iam_role_arn
  description = "IRSA role ARN to set on the ai-bot ServiceAccount."
}
