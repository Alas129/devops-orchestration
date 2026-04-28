output "controller_role_arn" {
  value = module.karpenter.iam_role_arn
}

output "node_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "interruption_queue_name" {
  value = module.karpenter.queue_name
}

output "current_bottlerocket_ami_id" {
  description = "AMI ID resolved at apply time. Bumping Bottlerocket = re-apply, drift triggers rotation."
  value       = data.aws_ssm_parameter.bottlerocket_ami.value
}
