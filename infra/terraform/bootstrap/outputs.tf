output "state_bucket" {
  description = "S3 bucket holding Terraform state (use as backend.bucket in every env)"
  value       = aws_s3_bucket.tfstate.bucket
}

output "lock_table" {
  description = "DynamoDB table for state locking"
  value       = aws_dynamodb_table.tflock.name
}

output "kms_key_arn" {
  description = "KMS key ARN used for state encryption"
  value       = aws_kms_key.tfstate.arn
}

output "region" {
  description = "AWS region the state lives in"
  value       = var.region
}

output "backend_snippet" {
  description = "Drop-in backend block for env modules"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.bucket}"
        key            = "<env>/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.tflock.name}"
        encrypt        = true
        kms_key_id     = "${aws_kms_key.tfstate.arn}"
      }
    }
  EOT
}
