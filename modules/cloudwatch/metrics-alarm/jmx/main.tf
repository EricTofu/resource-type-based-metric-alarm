#------------------------------------------------------------------------------
# JMX / JVM Monitoring Module
# Alarms on CloudWatch-Agent-emitted JVM metrics (namespace CWAgent, dim InstanceId).
# See cwagent/jmx/ for the agent config that produces these metrics.
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
  name_prefix   = "${var.project}-${var.env}-JMX"
  jmx_resources = { for res in var.resources : res.name => res }

  default_severities = {
    heap_used = "WARN"
    gc_time   = "WARN"
  }
}

#------------------------------------------------------------------------------
# Resolve EC2 instance IDs from Name tag (same pattern as the EC2 module).
#------------------------------------------------------------------------------

data "aws_instances" "by_name" {
  for_each = local.jmx_resources

  filter {
    name   = "tag:Name"
    values = [each.value.name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

check "jmx_name_tag_uniqueness" {
  assert {
    condition = alltrue([
      for k, d in data.aws_instances.by_name : length(d.ids) == 1
    ])
    error_message = "Every JMX resource must have exactly one running/stopped instance with a matching Name tag. Check: ${join(", ", [for k, d in data.aws_instances.by_name : "${k}=${length(d.ids)}" if length(d.ids) != 1])}"
  }
}

data "aws_instance" "this" {
  for_each = local.jmx_resources

  filter {
    name   = "tag:Name"
    values = [each.value.name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

#------------------------------------------------------------------------------
# Heap used (%) — metric math 100 * used / max
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "heap_used" {
  for_each = {
    for k, v in local.jmx_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "heap_used")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-HeapUsedPercent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-HeapUsedPercent is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.heap_threshold, null),
    var.default_heap_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "e1"
    expression  = "100*m1/m2"
    label       = "HeapUsedPercent"
    return_data = true
  }

  metric_query {
    id = "m1"
    metric {
      namespace   = "CWAgent"
      metric_name = "jvm.memory.heap.used"
      stat        = "Average"
      period      = 60
      dimensions  = { InstanceId = data.aws_instance.this[each.key].id }
    }
  }

  metric_query {
    id = "m2"
    metric {
      namespace   = "CWAgent"
      metric_name = "jvm.memory.heap.max"
      stat        = "Average"
      period      = 60
      dimensions  = { InstanceId = data.aws_instance.this[each.key].id }
    }
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "JMX"
      ResourceName = each.value.name
    }
  )
}

#------------------------------------------------------------------------------
# GC time (ms per minute) — DIFF of the cumulative jvm.gc.collections.elapsed counter.
# A JVM restart resets the counter -> negative DIFF -> never breaches (alarm is '>').
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "gc_time" {
  for_each = {
    for k, v in local.jmx_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "gc_time")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-GcTimeMsPerMinute"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.gc_time)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-GcTimeMsPerMinute is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.gc_time_threshold_ms, null),
    var.default_gc_time_threshold_ms
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "e1"
    expression  = "DIFF(m1)"
    label       = "GcTimeMsPerMinute"
    return_data = true
  }

  metric_query {
    id = "m1"
    metric {
      namespace   = "CWAgent"
      metric_name = "jvm.gc.collections.elapsed"
      stat        = "Maximum"
      period      = 60
      dimensions  = { InstanceId = data.aws_instance.this[each.key].id }
    }
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.gc_time)]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.gc_time)]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "JMX"
      ResourceName = each.value.name
    }
  )
}
