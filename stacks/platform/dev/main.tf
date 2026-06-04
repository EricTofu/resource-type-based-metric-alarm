locals {
  severities = ["WARN", "ERROR", "CRIT"]

  sns_topic_arns = var.sns_choice == "import" ? var.existing_sns_arns : {
    for sev in local.severities :
    sev => aws_sns_topic.regional[sev].arn
  }

  sns_topic_arns_global = var.sns_choice == "import" ? {
    for sev in local.severities :
    sev => var.existing_sns_arns[sev]  # Assuming existing ARNs are valid for us-east-1 too
  } : {
    for sev in local.severities :
    sev => aws_sns_topic.global[sev].arn
  }
}

# Regional SNS topics (primary region)
resource "aws_sns_topic" "regional" {
  for_each = toset(local.severities)

  name = "${var.alias}-${lower(each.key)}-alarms"

  tags = merge(var.common_tags, {
    Severity   = each.key
    Account    = var.alias
    ManagedBy  = "Terraform"
  })
}

# Global SNS topics (us-east-1 for CloudFront)
resource "aws_sns_topic" "global" {
  for_each = toset(local.severities)
  provider = aws.us_east_1

  name = "${var.alias}-${lower(each.key)}-alarms-global"

  tags = merge(var.common_tags, {
    Severity   = each.key
    Account    = var.alias
    ManagedBy  = "Terraform"
    Region     = "us-east-1"
  })
}