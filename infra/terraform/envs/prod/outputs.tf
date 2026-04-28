output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "rds_resource_id" {
  value = module.rds.resource_id
}

output "rds_master_secret_arn" {
  value = module.rds.master_secret_arn
}

output "acm_certificate_arn" {
  value = module.acm_prod.certificate_arn
}

output "service_irsa_role_arns" {
  value = { for k, v in module.service_irsa : k => v.iam_role_arn }
}

output "current_bottlerocket_ami_id" {
  value = module.karpenter.current_bottlerocket_ami_id
}

output "argocd_url" {
  value = module.argocd.argocd_url
}

output "grafana_url" {
  value = module.monitoring.grafana_url
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
