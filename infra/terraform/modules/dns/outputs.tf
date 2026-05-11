output "zone_id" {
  description = "Cloudflare zone ID — pass through to ACM and platform-bootstrap modules."
  value       = data.cloudflare_zone.this.id
}

output "name" {
  description = "Apex domain name."
  value       = data.cloudflare_zone.this.name
}
