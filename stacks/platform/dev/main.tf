locals {
  severities = ["WARN", "ERROR", "CRIT"]
  tier       = replace(var.alias, "account-", "")
}

resource "aws_sns_topic" "regional" {
  for_each = var.sns_choice == "create" ? toset(local.severities) : toset([])

  name = "${local.tier}-${lower(each.key)}-alerts"
  tags = merge(var.common_tags, { Severity = each.key, Scope = "regional" })
}

resource "aws_sns_topic" "global" {
  provider = aws.us_east_1
  for_each = var.sns_choice == "create" ? toset(local.severities) : toset([])

  name = "${local.tier}-${lower(each.key)}-alerts-global"
  tags = merge(var.common_tags, { Severity = each.key, Scope = "global" })
}
