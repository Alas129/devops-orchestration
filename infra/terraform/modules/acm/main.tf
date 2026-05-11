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

# One Cloudflare DNS record per unique validation entry. ACM emits one
# domain_validation_options entry per SAN, but the SAN-wildcard pair often
# share the same record, so we dedupe by record name.
locals {
  validations = {
    for dvo in aws_acm_certificate.this.domain_validation_options :
    dvo.resource_record_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}

resource "cloudflare_record" "validation" {
  for_each = local.validations

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  content = trimsuffix(each.value.value, ".")
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
