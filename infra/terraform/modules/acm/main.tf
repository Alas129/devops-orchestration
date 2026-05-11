# ACM certificate with DNS validation. The validation records live in
# Cloudflare (this is the only place we touch Cloudflare directly besides
# external-dns), and we wait for ACM to confirm them before returning.
#
# The cert covers var.fqdn plus a one-level wildcard (e.g.
# fqdn="dev.calmloop.space" gets a cert for "dev.calmloop.space" and
# "*.dev.calmloop.space").

resource "aws_acm_certificate" "this" {
  domain_name = var.fqdn
  subject_alternative_names = concat(
    ["*.${var.fqdn}"],
    var.additional_sans,
  )
  validation_method = "DNS"

  tags = {
    Name = var.fqdn
  }

  lifecycle {
    create_before_destroy = true
  }
}

# One Cloudflare DNS record per unique non-wildcard SAN. For wildcard SANs
# (e.g. *.dev.calmloop.space), ACM emits a validation record under the parent
# domain that ALSO covers the wildcard, so we don't iterate the wildcard
# separately.
#
# for_each keys must be known at plan time. We use the static SAN list rather
# than aws_acm_certificate.this.domain_validation_options (which is "known
# after apply" and breaks for_each). The values are looked up by domain.
locals {
  validation_domains = toset(concat([var.fqdn], var.additional_sans))
}

resource "cloudflare_record" "validation" {
  for_each = local.validation_domains

  zone_id = var.zone_id
  name    = one([for dvo in aws_acm_certificate.this.domain_validation_options : dvo.resource_record_name if dvo.domain_name == each.key])
  type    = one([for dvo in aws_acm_certificate.this.domain_validation_options : dvo.resource_record_type if dvo.domain_name == each.key])
  content = one([for dvo in aws_acm_certificate.this.domain_validation_options : trimsuffix(dvo.resource_record_value, ".") if dvo.domain_name == each.key])
  ttl     = 60
  proxied = false
  comment = "ACM DNS-01 validation for ${var.fqdn}"
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in cloudflare_record.validation : r.hostname]

  timeouts {
    create = "30m"
  }
}
