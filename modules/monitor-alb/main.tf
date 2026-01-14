locals {
  # Flatten resources for for_each
  alb_resources = { for res in var.resources : res.name => res }

  # Default severities per metric
  default_severities = {
    elb_5xx              = "WARN"
    target_5xx           = "WARN"
    unhealthy_host       = "ERROR"
    target_response_time = "WARN"
  }
}

#------------------------------------------------------------------------------
# Data source to get ALB ARN suffix from name
#------------------------------------------------------------------------------

data "aws_lb" "this" {
  for_each = local.alb_resources
  name     = each.value.name
}

#------------------------------------------------------------------------------
# HTTPCode_ELB_5XX_Count Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "elb_5xx" {
  for_each = local.alb_resources

  alarm_name = "${var.project}-ALB-${each.value.name}-HTTPCode_ELB_5XX_Count"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-ALB-${each.value.name}-HTTPCode_ELB_5XX_Count is in ALARM state"
  )

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.elb_5xx_threshold, null),
    var.default_elb_5xx_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    LoadBalancer = data.aws_lb.this[each.key].arn_suffix
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.elb_5xx
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "ALB"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# HTTPCode_Target_5XX_Count Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each = local.alb_resources

  alarm_name = "${var.project}-ALB-${each.value.name}-HTTPCode_Target_5XX_Count"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-ALB-${each.value.name}-HTTPCode_Target_5XX_Count is in ALARM state"
  )

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.target_5xx_threshold, null),
    var.default_target_5xx_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    LoadBalancer = data.aws_lb.this[each.key].arn_suffix
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.target_5xx
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "ALB"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# UnHealthyHostCount Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_host" {
  for_each = local.alb_resources

  alarm_name = "${var.project}-ALB-${each.value.name}-UnHealthyHostCount"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-ALB-${each.value.name}-UnHealthyHostCount is in ALARM state"
  )

  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Minimum"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.unhealthy_host_threshold, null),
    var.default_unhealthy_host_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    LoadBalancer = data.aws_lb.this[each.key].arn_suffix
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.unhealthy_host
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "ALB"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# TargetResponseTime Alarm (p90)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "target_response_time" {
  for_each = local.alb_resources

  alarm_name = "${var.project}-ALB-${each.value.name}-TargetResponseTime"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-ALB-${each.value.name}-TargetResponseTime is in ALARM state"
  )

  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p90"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.target_response_time_threshold, null),
    var.default_target_response_time_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    LoadBalancer = data.aws_lb.this[each.key].arn_suffix
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.target_response_time
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "ALB"
    ResourceName = each.value.name
  }
}
