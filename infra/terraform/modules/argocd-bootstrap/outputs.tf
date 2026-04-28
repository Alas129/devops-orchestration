output "argocd_url" {
  value = "https://argocd.${var.subdomain}.${var.domain_name}"
}
