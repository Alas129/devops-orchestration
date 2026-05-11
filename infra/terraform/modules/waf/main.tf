# WAFv2 Web ACL attached to the cluster's ALBs. Three rules:
#   1. Rate-based: cap requests per source IP at 2000 / 5 min
#   2. AWS Managed: Core Rule Set (OWASP-like baseline)
#   3. AWS Managed: Known Bad Inputs
#
# Cost: $5/month per ACL + $1/month per rule + $0.60 per million WCUs.
# For our traffic volume (~$7-10/month total).

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "ALB protection: rate limit + AWS Managed rules"
  scope       = "REGIONAL" # for ALB; CLOUDFRONT scope is global

  default_action {
    allow {}
  }

  # ── Rule 1: per-IP rate limit ───────────────────────────────────────────
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 2: AWS Common Rule Set ─────────────────────────────────────────
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    # `none` = use the rule group's own block/allow actions. Override with
    # `count` here while you're tuning false positives.
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 3: Known Bad Inputs (path traversal, log4j, etc) ───────────────
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-acl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = var.name
  }
}

# ── WAF logging to CloudWatch ──────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "waf" {
  count             = var.enable_logging ? 1 : 0
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = var.enable_logging ? 1 : 0
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
  resource_arn            = aws_wafv2_web_acl.this.arn

  # Don't log fields that often contain PII; AWS recommends redacting auth
  # headers and any custom session cookies.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
