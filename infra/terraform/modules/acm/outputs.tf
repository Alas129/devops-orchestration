output "certificate_arn" {
  value = module.acm.acm_certificate_arn
}

output "domain_name" {
  value = module.acm.distinct_domain_names[0]
}
