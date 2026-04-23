locals {
  apigateway_resources = { for res in var.resources : res.name => res }

  default_severities = {
    error_5xx = "WARN"
  }
}

#------------------------------------------------------------------------------
# 5XXError Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "error_5xx" {
  for_each = local.apigateway_resources

  alarm_name = "${var.project}-APIGateway-[${each.value.name}]-5XXError"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.error_5xx)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-APIGateway-[${each.value.name}]-5XXError is in ALARM state"
  )}"

  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.error_5xx_threshold, null),
    var.default_5xx_error_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  period              = 60

  dimensions = {
    ApiName = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.error_5xx
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "APIGateway"
    ResourceName = each.value.name
  }
}
