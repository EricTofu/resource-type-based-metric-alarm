#------------------------------------------------------------------------------
# JMX / JVM Monitoring Module
# Alarms on CloudWatch-Agent-emitted JVM metrics via Metrics Insights, scoped by
# the agent's AppName dimension and grouped per InstanceId — so one entry covers
# a whole fleet and membership re-resolves at every evaluation. There is NO
# instance lookup: duplicate Name tags (normal inside an ASG) are irrelevant, and
# CodeDeploy blue/green churn needs no re-apply.
# See cwagent/ec2-java/ for the agent config that produces these metrics.
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

  # Optional extra scope for hosts running more than one JVM. Empty string when
  # unset, so the query strings below concatenate unconditionally.
  pg_filter = {
    for k, v in local.jmx_resources : k =>
    v.process_group != null ? " AND ProcessGroupName = '${v.process_group}'" : ""
  }

  default_severities = {
    heap_used = "WARN"
    gc_time   = "WARN"
  }
}

#------------------------------------------------------------------------------
# Heap used (bytes) — byte threshold from the entry's known -Xmx.
# CloudWatch math cannot divide two GROUP BY series arrays elementwise, so the
# old 100*used/max ratio is not expressible per-instance; for a homogeneous
# group with a known -Xmx the byte threshold is equivalent.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "heap_used" {
  for_each = {
    for k, v in local.jmx_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "heap_used")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-HeapUsedBytes"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-HeapUsedBytes is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = floor(
    coalesce(
      try(each.value.overrides.heap_threshold, null),
      var.default_heap_threshold
    ) * each.value.heap_max_bytes / 100
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  # GROUP BY InstanceId: one series per instance; ALARM when ANY series breaches.
  # Plain FROM "CWAgent" (not SCHEMA) tolerates the extra dimensions the JMX
  # receiver adds (per-collector `name`, ProcessGroupName).
  metric_query {
    id          = "q1"
    return_data = true
    period      = 60
    expression  = "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'${local.pg_filter[each.key]} GROUP BY InstanceId"
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
# GC time (ms per minute) — DIFF of the cumulative jvm_gc_collections_elapsed
# counter. DIFF over a multi-series GROUP BY result returns one series per
# instance (verified); the SQL must be its own query referenced by id, because
# metric math cannot be nested inside a Metrics Insights query.
#
# SELECT SUM totals time-in-GC across the per-collector (`name` dimension)
# series within each instance — the receiver emits one series per garbage
# collector. Correct while JMX collects at 60s = this period (one datapoint per
# period); if the collection interval drops below 60s, revisit (a summed
# cumulative counter would over-count).
#
# A JVM restart resets the counter -> negative DIFF -> never breaches (alarm is
# '>'). Fails safe: misses, never false-fires. The first datapoint of a series
# has no predecessor and produces no value.
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
    expression  = "DIFF(q1)"
    label       = "GcTimeMsPerMinute"
    return_data = true
  }

  metric_query {
    id          = "q1"
    return_data = false
    period      = 60
    expression  = "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'${local.pg_filter[each.key]} GROUP BY InstanceId"
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
