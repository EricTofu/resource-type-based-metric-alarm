locals {
  name_prefix   = "${var.project}-${var.env}-ASG"
  asg_resources = { for res in var.resources : res.name => res }

  # asg_tag_value is the fleet-mode latch: null = legacy dimension alarm only.
  # A validation in variables.tf keeps it paired with cwagent_dimension_value,
  # so a fleet entry always has both halves of its identity.
  legacy_resources = { for k, v in local.asg_resources : k => v if v.asg_tag_value == null }
  fleet_resources  = { for k, v in local.asg_resources : k => v if v.asg_tag_value != null }

  # One key/value pair per system. Built once here so each query below reads as
  # a single mechanism, and so the difference is visible rather than buried
  # mid-string:
  #
  #   tag_filter       -> AWS resource tag, joined server-side by CloudWatch.
  #                       Needs "resource tags on telemetry" (account + region).
  #                       Used by the NATIVE-metric alarms (capacity, cpu).
  #   cwagent_filter   -> a dimension the agent stamps on what it publishes.
  #                       Needs nothing enabled; needs the agent config to match.
  #                       Used by the CWAGENT-sourced alarms (memory, disk).
  #
  # Conflating them is the failure this layout exists to prevent: a fleet can be
  # fully tagged and still have no CWAgent series, or vice versa.
  tag_filter     = { for k, v in local.fleet_resources : k => "tag.${var.asg_tag_key} = '${v.asg_tag_value}'" }
  cwagent_filter = { for k, v in local.fleet_resources : k => "${var.cwagent_dimension_key} = '${v.cwagent_dimension_value}'" }

  default_severities = {
    in_service_capacity = "CRIT"
    cpu                 = "WARN"
    memory              = "WARN"
    disk                = "WARN"
  }
}

#------------------------------------------------------------------------------
# GroupInServiceCapacity Alarm (legacy mode: AutoScalingGroupName dimension)
#
# NOTE: this renders the same alarm_name as fleet_in_service_capacity below.
# Adding/removing asg_tag_value on an existing entry needs a TWO-APPLY migration —
# see the MIGRATION FOOTGUN comment on that resource before doing it.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "in_service_capacity" {
  for_each = {
    for k, v in local.legacy_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "in_service_capacity")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-GroupInServiceCapacity"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.in_service_capacity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-GroupInServiceCapacity is in ALARM state"
  )}"

  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceCapacity"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.capacity_threshold, null),
    each.value.desired_capacity
  )
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  period              = 60

  dimensions = {
    AutoScalingGroupName = each.value.name
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.in_service_capacity
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.in_service_capacity
    )]
  ] : []

  treat_missing_data = "breaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

#------------------------------------------------------------------------------
# Fleet mode (asg_tag_value set): identity-scoped Metrics Insights alarms — capacity
# and cpu via the resource tag, memory and disk via the CWAgent dimension.
# Membership resolves at evaluation time — ASG/instance churn needs no apply.
# A metric_query alarm cannot carry dimensions, hence separate resources.
#------------------------------------------------------------------------------

#  ############################################################################
#  ## MIGRATION FOOTGUN — READ BEFORE LATCHING FLEET MODE ON AN EXISTING     ##
#  ## ENTRY (i.e. adding asg_tag_value to one already in state).              ##
#  ############################################################################
#
#  This alarm and aws_cloudwatch_metric_alarm.in_service_capacity above render
#  the SAME alarm name: "${local.name_prefix}-[${name}]-GroupInServiceCapacity".
#  That is deliberate — the naming convention is fixed (CLAUDE.md) and the alarm
#  means the same thing in both modes. But CloudWatch alarm names are the API's
#  identity: PutMetricAlarm upserts by name, DeleteAlarms deletes by name.
#
#  So adding asg_tag_value to an entry already in state produces, in ONE
#  plan, a create of fleet_in_service_capacity["k"] AND a destroy of
#  in_service_capacity["k"] — two unrelated resource addresses with no
#  dependency edge, which Terraform is free to run concurrently. If the destroy
#  lands second, it DELETES the alarm the create just made: state says the
#  CRIT-severity capacity watchdog exists, CloudWatch says it does not, and the
#  pager is silently disarmed until someone notices or re-applies.
#
#  A `moved` block cannot fix this: it is static, so it would also move entries
#  that legitimately stay in legacy mode.
#
#  REQUIRED PROCEDURE — flip the mode over TWO applies:
#    1. Remove the entry from the *_resources list.  ->  terraform apply
#       (destroys the legacy alarm; confirm it is gone in CloudWatch)
#    2. Re-add it with asg_tag_value + cwagent_dimension_value. -> apply
#       (creates the fleet alarms; the name is now free)
#  Alternative: delete the legacy alarm out-of-band (`aws cloudwatch
#  delete-alarms --alarm-names ...` + `terraform state rm`) BEFORE the apply
#  that latches fleet mode.
#
#  The same collision applies in reverse (removing asg_tag_value from an entry).
#  The three per-instance fleet alarms are unaffected: their names have no legacy
#  counterpart.
#
resource "aws_cloudwatch_metric_alarm" "fleet_in_service_capacity" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "in_service_capacity")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-GroupInServiceCapacity"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.in_service_capacity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-GroupInServiceCapacity is in ALARM state"
  )}"

  comparison_operator = "LessThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.capacity_threshold, null),
    each.value.desired_capacity
  )
  evaluation_periods  = 10
  datapoints_to_alarm = 10

  # SUM deliberately counts old+new ASGs during blue/green overlap: it can only
  # over-count, which briefly masks (never false-fires) LessThanThreshold.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 60
    expression  = "SELECT SUM(GroupInServiceCapacity) FROM SCHEMA(\"AWS/AutoScaling\", AutoScalingGroupName) WHERE ${local.tag_filter[each.key]}"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.in_service_capacity
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.in_service_capacity
    )]
  ] : []

  treat_missing_data = "breaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "fleet_cpu" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "cpu")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-CPUUtilization"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.cpu)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-CPUUtilization is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.cpu_threshold, null),
    var.default_cpu_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  # GROUP BY InstanceId: one series per instance; each becomes an alarm
  # contributor and the alarm enters ALARM as soon as one of them breaches.
  #
  # ORDER BY is REQUIRED: PutMetricAlarm rejects any expression returning
  # multiple time series unless it is a Metrics Insights expression carrying an
  # ORDER BY clause. It also selects which 500 series are evaluated in a group
  # larger than that — DESC keeps the busiest instances.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    expression  = "SELECT AVG(CPUUtilization) FROM SCHEMA(\"AWS/EC2\", InstanceId) WHERE ${local.tag_filter[each.key]} GROUP BY InstanceId ORDER BY AVG() DESC"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.cpu
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.cpu
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "fleet_memory" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "memory")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-mem_used_percent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.memory)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-mem_used_percent is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  # Guardrail only (default 90): JVM hosts sit at 75-85% OS memory by design.
  # JVM memory pressure is the jmx module's job.
  threshold = coalesce(
    try(each.value.overrides.memory_threshold, null),
    var.default_memory_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    # ORDER BY required for a multi-series alarm — see the cpu alarm above.
    expression = "SELECT AVG(mem_used_percent) FROM \"CWAgent\" WHERE ${local.cwagent_filter[each.key]} GROUP BY InstanceId ORDER BY AVG() DESC"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.memory
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.memory
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "fleet_disk" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "disk")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-disk_used_percent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.disk)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-disk_used_percent is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.disk_threshold, null),
    var.default_disk_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    # ORDER BY required for a multi-series alarm — see the cpu alarm above.
    expression = "SELECT AVG(disk_used_percent) FROM \"CWAgent\" WHERE ${local.cwagent_filter[each.key]} AND path = '/' GROUP BY InstanceId ORDER BY AVG() DESC"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.disk
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.disk
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}
