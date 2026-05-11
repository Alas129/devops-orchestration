# Reads an existing Cloudflare zone (the user-registered domain whose
# nameservers point at Cloudflare). External-DNS in the cluster will then
# create records under this zone via the Cloudflare API.

data "cloudflare_zone" "this" {
  name = var.domain_name
}
