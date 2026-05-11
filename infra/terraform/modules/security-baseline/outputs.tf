output "guardduty_detector_id" {
  value = try(aws_guardduty_detector.this[0].id, null)
}

output "cloudtrail_bucket" {
  value = try(aws_s3_bucket.cloudtrail[0].id, null)
}

output "config_bucket" {
  value = try(aws_s3_bucket.config[0].id, null)
}
