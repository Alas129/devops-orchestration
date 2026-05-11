output "web_acl_arn" {
  description = "Web ACL ARN — pass to Helm chart values.ingress.wafAclArn."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  value = aws_wafv2_web_acl.this.id
}
