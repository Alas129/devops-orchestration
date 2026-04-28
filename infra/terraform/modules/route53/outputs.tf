output "zone_id" {
  value = data.aws_route53_zone.this.zone_id
}

output "zone_arn" {
  value = data.aws_route53_zone.this.arn
}

output "name" {
  value = data.aws_route53_zone.this.name
}
