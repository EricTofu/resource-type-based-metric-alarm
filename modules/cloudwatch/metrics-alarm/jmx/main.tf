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
    heap_used = "ERROR"
    gc_time   = "ERROR"
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
  # Long window on purpose: a healthy JVM touches 90% of -Xmx just before a
  # collection, so a short window fires on the sawtooth. Only a heap that stays
  # high for the whole window indicates a post-GC live set that does not fit —
  # which is also what a GC spiral looks like from the heap side.
  evaluation_periods = coalesce(
    try(each.value.overrides.heap_evaluation_periods, null),
    var.default_heap_evaluation_periods
  )
  datapoints_to_alarm = coalesce(
    try(each.value.overrides.heap_evaluation_periods, null),
    var.default_heap_evaluation_periods
  )

  # GROUP BY InstanceId: one series per instance; each becomes an alarm
  # contributor and the alarm enters ALARM as soon as one of them breaches.
  # Plain FROM "CWAgent" (not SCHEMA) tolerates the extra dimensions the JMX
  # receiver adds (per-collector `name`, ProcessGroupName).
  #
  # ORDER BY is REQUIRED, not decorative: PutMetricAlarm rejects any expression
  # returning multiple time series ("Metrics expression that return multi time
  # series are only allowed for MetricsInsights expression with an ORDER BY
  # clause") — a GROUP BY query without it fails at apply. It also picks which
  # 500 series are evaluated when the group is larger than that; DESC keeps the
  # highest heap users, which are the ones this alarm is looking for.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 60
    expression  = "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${each.value.cwagent_dimension_value}'${local.pg_filter[each.key]} GROUP BY InstanceId ORDER BY AVG() DESC"
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
# GC time (ms per minute) — a plain gauge query, NOT metric math.
#
# The CloudWatch agent applies a `cumulativetodelta/jmx` processor before
# publishing (see the translated pipeline at
# /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.yaml), so
# jvm_gc_collections_elapsed reaches CloudWatch already as milliseconds of GC
# per 60s collection interval — verified over a 3h span: it rises and returns
# to 0 instead of climbing. `initial_value: 2` drops the first point.
#
# The previous DIFF(q1) form was wrong twice over: PutMetricAlarm rejects metric
# math wrapping a multi-series query, AND differencing an already-differenced
# series measures the CHANGE in GC time (acceleration), not GC time. The
# "JVM restart resets the counter -> negative DIFF -> fails safe" reasoning
# guarded against a reset that never reaches CloudWatch.
#
# SUM totals time-in-GC across the per-collector `name` series within each
# instance. The threshold is ms of GC per minute: 6000 = 10% of wall clock, the
# standard GC-overhead heuristic.
#
# CAUTION: "ms per interval" equals "ms per minute" only while the agent's
# metrics_collection_interval is 60. Halve the interval and every threshold here
# silently halves in meaning.
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
  evaluation_periods  = 5
  datapoints_to_alarm = 5

  # Five consecutive minutes, so a single stop-the-world burst does not fire it.
  # ORDER BY is required for a multi-series alarm — see heap_used above.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 60
    expression  = "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${each.value.cwagent_dimension_value}'${local.pg_filter[each.key]} GROUP BY InstanceId ORDER BY SUM() DESC"
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
