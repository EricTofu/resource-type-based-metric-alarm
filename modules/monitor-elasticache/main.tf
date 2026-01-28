locals {
  elasticache_resources = { for res in var.resources : res.name => res }
  default_severity      = "ERROR"
}

#------------------------------------------------------------------------------
# CPUUtilization Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each = local.elasticache_resources

  alarm_name = "${var.project}-ElastiCache-[${each.value.name}]-CPUUtilization"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-ElastiCache-[${each.value.name}]-CPUUtilization is in ALARM state"
  )}"

  namespace           = "AWS/ElastiCache"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.cpu_threshold, null),
    var.default_cpu_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    CacheClusterId = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severity
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "ElastiCache"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# DatabaseMemoryUsagePercentage Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "memory" {
  for_each = local.elasticache_resources

  alarm_name = "${var.project}-ElastiCache-[${each.value.name}]-DatabaseMemoryUsagePercentage"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-ElastiCache-[${each.value.name}]-DatabaseMemoryUsagePercentage is in ALARM state"
  )}"

  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.memory_threshold, null),
    var.default_memory_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    CacheClusterId = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severity
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "ElastiCache"
    ResourceName = each.value.name
  }
}
