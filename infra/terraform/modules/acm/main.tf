module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.1"

  domain_name = var.fqdn
  zone_id     = var.zone_id

  subject_alternative_names = concat(
    ["*.${var.fqdn}"],
    var.additional_sans,
  )

  validation_method   = "DNS"
  wait_for_validation = true

  tags = {
    Name = var.fqdn
  }
}
