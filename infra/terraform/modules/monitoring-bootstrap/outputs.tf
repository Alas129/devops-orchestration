output "grafana_url" {
  value = "https://grafana.${var.subdomain}.${var.domain_name}"
}

output "namespace" {
  value = kubernetes_namespace_v1.monitoring.metadata[0].name
}
