#------------------------------------------------------------------------------
# EFS Monitoring Module
#------------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  name_prefix   = "${var.project}-${var.env}-EFS"
  efs_resources = { for res in var.resources : res.file_system_id => res }

  default_severities = {
    throughput_util = "WARN"
  }
}

#------------------------------------------------------------------------------
# Throughput Utilization (%) — metric-math alarm.
# Not a published metric: utilization = metered throughput / permitted throughput.
#   metered MiBps  = Sum(MeteredIOBytes) / PERIOD
#   permitted Bps  = Average(PermittedThroughput)
# Watched over a long span (default 3600s x 6 = 6h sustained) to track the trend
# rather than fire on short spikes.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "throughput_util" {
  for_each = {
    for k, v in local.efs_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "throughput_util")
  }

  alarm_name = "${local.name_prefix}-[${coalesce(each.value.name, each.value.file_system_id)}]-ThroughputUtilization"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.throughput_util)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${coalesce(each.value.name, each.value.file_system_id)}]-ThroughputUtilization is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.throughput_util_threshold, null),
    var.default_throughput_util_threshold
  )
  evaluation_periods  = coalesce(try(each.value.overrides.evaluation_periods, null), 6)
  datapoints_to_alarm = coalesce(try(each.value.overrides.evaluation_periods, null), 6)

  metric_query {
    id          = "e1"
    expression  = "100*(m1/PERIOD(m1))/m2"
    label       = "ThroughputUtilization"
    return_data = true
  }

  metric_query {
    id = "m1"
    metric {
      namespace   = "AWS/EFS"
      metric_name = "MeteredIOBytes"
      stat        = "Sum"
      period      = coalesce(try(each.value.overrides.period, null), 3600)
      dimensions  = { FileSystemId = each.value.file_system_id }
    }
  }

  metric_query {
    id = "m2"
    metric {
      namespace   = "AWS/EFS"
      metric_name = "PermittedThroughput"
      stat        = "Average"
      period      = coalesce(try(each.value.overrides.period, null), 3600)
      dimensions  = { FileSystemId = each.value.file_system_id }
    }
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.throughput_util)]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.throughput_util)]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "EFS"
      ResourceName = coalesce(each.value.name, each.value.file_system_id)
    }
  )
}
