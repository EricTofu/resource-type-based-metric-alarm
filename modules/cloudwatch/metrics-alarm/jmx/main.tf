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
    expression  = "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'${local.pg_filter[each.key]} GROUP BY InstanceId ORDER BY AVG() DESC"
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
# GC time — REMOVED (2026-07-31).
#
# The alarm was DIFF(q1) over `SELECT SUM(jvm_gc_collections_elapsed) … GROUP BY
# InstanceId`. PutMetricAlarm rejects it:
#
#   ValidationError: Metrics expression that return multi time series are only
#   allowed for MetricsInsights expression with an ORDER BY clause
#
# Any expression backing an alarm must return a single time series; the sole
# exception is a Metrics Insights expression carrying ORDER BY. DIFF(q1) is
# metric math, not an Insights expression, so no ORDER BY inside q1 rescues it —
# and RATE() fails identically. This resolves the 2026-07-30 spec's blocking
# verify item 2 in the negative.
#
# Dropped rather than reshaped, per that spec's fallback 3: heap exhaustion and
# GC thrash almost always arrive together, so `heap_used` above still catches
# the incident. The gap left behind is a JVM that thrashes GC without filling
# heap. Two ways back if that gap bites:
#   1. agent-side delta temporality on jvm_gc_collections_elapsed — then the
#      alarm is a plain Insights query with ORDER BY and no math at all;
#   2. drop GROUP BY so DIFF returns one series — legal, but it sums GC time
#      across the group, so one sick JVM is diluted by healthy ones.
# The GC widgets in modules/cloudwatch/dashboard/jmx are unaffected: dashboards
# use GetMetricData, which has no single-series constraint.
#------------------------------------------------------------------------------
