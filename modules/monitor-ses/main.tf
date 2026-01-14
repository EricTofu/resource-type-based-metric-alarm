locals {
  ses_resources    = { for res in var.resources : res.name => res }
  default_severity = "WARN"
}

#------------------------------------------------------------------------------
# Reputation.BounceRate Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "bounce_rate" {
  for_each = local.ses_resources

  alarm_name = "${var.project}-SES-${each.value.name}-Reputation.BounceRate"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-SES-${each.value.name}-Reputation.BounceRate is in ALARM state"
  )

  namespace           = "AWS/SES"
  metric_name         = "Reputation.BounceRate"
  statistic           = "Average"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold = coalesce(
    try(each.value.overrides.bounce_rate_threshold, null),
    var.default_bounce_rate_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severity
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "SES"
    ResourceName = each.value.name
  }
}
