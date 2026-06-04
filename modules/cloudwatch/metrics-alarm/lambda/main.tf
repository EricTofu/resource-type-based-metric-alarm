locals {
  lambda_resources = { for res in var.resources : res.name => res }

  default_severities = {
    duration    = "WARN"
    concurrency = "WARN"
  }
}

#------------------------------------------------------------------------------
# Duration Alarm (p90, 90% of timeout)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "duration" {
  for_each = local.lambda_resources

  alarm_name = "${var.project}-Lambda-[${each.value.name}]-Duration"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.duration)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-Lambda-[${each.value.name}]-Duration is in ALARM state"
  )}"

  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  extended_statistic  = "p90"
  comparison_operator = "GreaterThanThreshold"
  # Use override or 90% of timeout
  threshold = coalesce(
    try(each.value.overrides.duration_threshold_ms, null),
    each.value.timeout_ms * 0.9
  )
  evaluation_periods  = 15
  datapoints_to_alarm = 15
  period              = 60

  dimensions = {
    FunctionName = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.duration
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "Lambda"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# ClaimedAccountConcurrency Alarm (Account-level, created once per project)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "concurrency" {
  count = length(var.resources) > 0 ? 1 : 0

  alarm_name        = "${var.project}-Lambda-[Account]-ClaimedAccountConcurrency"
  alarm_description = "[${local.default_severities.concurrency}]-${var.project}-Lambda-ClaimedAccountConcurrency is in ALARM state"

  namespace           = "AWS/Lambda"
  metric_name         = "ClaimedAccountConcurrency"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.concurrency_threshold
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  period              = 60

  alarm_actions = [var.sns_topic_arns[local.default_severities.concurrency]]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "Lambda"
    ResourceName = "Account"
  }
}
