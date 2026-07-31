locals {
  name_prefix = "${var.project}-${var.env}-ALB"
  # Flatten resources for for_each
  alb_resources = { for res in var.resources : res.name => res }

  # UnHealthyHostCount is only published per (TargetGroup, LoadBalancer),
  # so that alarm fans out to one per ALB/target-group pair.
  alb_tg_pairs = merge([
    for alb_key, alb in local.alb_resources : {
      for tg in alb.target_groups : "${alb_key}:${tg}" => {
        alb_key = alb_key
        alb     = alb
        tg      = tg
      }
    } if !contains(try(alb.overrides.disabled_alarms, []), "unhealthy_host")
  ]...)

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

data "aws_lb_target_group" "this" {
  for_each = local.alb_tg_pairs
  name     = each.value.tg
}

#------------------------------------------------------------------------------
# HTTPCode_ELB_5XX_Count Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "elb_5xx" {
  for_each = {
    for k, v in local.alb_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "elb_5xx")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-HTTPCode_ELB_5XX_Count"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.elb_5xx)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-HTTPCode_ELB_5XX_Count is in ALARM state"
  )}"

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

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.elb_5xx
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.elb_5xx
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ALB"
      ResourceName = each.value.name
    }
  )
}

#------------------------------------------------------------------------------
# HTTPCode_Target_5XX_Count Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each = {
    for k, v in local.alb_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "target_5xx")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-HTTPCode_Target_5XX_Count"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.target_5xx)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-HTTPCode_Target_5XX_Count is in ALARM state"
  )}"

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

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.target_5xx
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.target_5xx
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ALB"
      ResourceName = each.value.name
    }
  )
}

#------------------------------------------------------------------------------
# UnHealthyHostCount Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_host" {
  for_each = local.alb_tg_pairs

  alarm_name = "${local.name_prefix}-[${each.value.alb.name}/${each.value.tg}]-UnHealthyHostCount"
  alarm_description = "[${coalesce(try(each.value.alb.overrides.severity, null), local.default_severities.unhealthy_host)}]-${coalesce(
    try(each.value.alb.overrides.description, null),
    "${local.name_prefix}-[${each.value.alb.name}/${each.value.tg}]-UnHealthyHostCount is in ALARM state"
  )}"

  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Minimum"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.alb.overrides.unhealthy_host_threshold, null),
    var.default_unhealthy_host_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    LoadBalancer = data.aws_lb.this[each.value.alb_key].arn_suffix
    TargetGroup  = data.aws_lb_target_group.this[each.key].arn_suffix
  }

  alarm_actions = each.value.alb.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.alb.overrides.severity, null),
      local.default_severities.unhealthy_host
    )]
  ] : []

  ok_actions = each.value.alb.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.alb.overrides.severity, null),
      local.default_severities.unhealthy_host
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ALB"
      ResourceName = each.value.alb.name
      TargetGroup  = each.value.tg
    }
  )
}

#------------------------------------------------------------------------------
# TargetResponseTime Alarm (p90)
#
# Re-enabled 2026-07-31: this is the symptom a JVM GC spiral (or any downstream
# stall) produces BEFORE anything returns 5xx. With it disabled, that failure
# mode reached users with no alarm at all. CRIT per the alerting policy.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "target_response_time" {
  for_each = local.alb_resources

  alarm_name = "${local.name_prefix}-[${each.value.name}]-TargetResponseTime"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.target_response_time)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-TargetResponseTime is in ALARM state"
  )}"

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

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.target_response_time
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.target_response_time
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ALB"
      ResourceName = each.value.name
    }
  )
}
