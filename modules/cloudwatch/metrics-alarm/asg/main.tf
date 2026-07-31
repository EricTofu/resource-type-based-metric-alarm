locals {
  name_prefix   = "${var.project}-${var.env}-ASG"
  asg_resources = { for res in var.resources : res.name => res }

  # app_name is the fleet-mode latch: null = legacy dimension alarm only.
  legacy_resources = { for k, v in local.asg_resources : k => v if v.app_name == null }
  fleet_resources  = { for k, v in local.asg_resources : k => v if v.app_name != null }

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
# Adding/removing app_name on an existing entry needs a TWO-APPLY migration —
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
# Fleet mode (app_name set): AppName-scoped Metrics Insights alarms.
# Membership resolves at evaluation time — ASG/instance churn needs no apply.
# A metric_query alarm cannot carry dimensions, hence separate resources.
#------------------------------------------------------------------------------

#  ############################################################################
#  ## MIGRATION FOOTGUN — READ BEFORE ADDING app_name TO AN EXISTING ENTRY.  ##
#  ############################################################################
#
#  This alarm and aws_cloudwatch_metric_alarm.in_service_capacity above render
#  the SAME alarm name: "${local.name_prefix}-[${name}]-GroupInServiceCapacity".
#  That is deliberate — the naming convention is fixed (CLAUDE.md) and the alarm
#  means the same thing in both modes. But CloudWatch alarm names are the API's
#  identity: PutMetricAlarm upserts by name, DeleteAlarms deletes by name.
#
#  So adding app_name to an entry that already exists in state produces, in ONE
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
#    2. Re-add the entry with app_name.  -> terraform apply
#       (creates the fleet alarms; the name is now free)
#  Alternative: delete the legacy alarm out-of-band (`aws cloudwatch
#  delete-alarms --alarm-names ...` + `terraform state rm`) BEFORE the apply
#  that adds app_name.
#
#  The same collision applies in reverse (removing app_name from an entry).
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
    expression  = "SELECT SUM(GroupInServiceCapacity) FROM SCHEMA(\"AWS/AutoScaling\", AutoScalingGroupName) WHERE tag.${var.app_tag_key} = '${each.value.app_name}'"
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
    expression  = "SELECT AVG(CPUUtilization) FROM SCHEMA(\"AWS/EC2\", InstanceId) WHERE tag.${var.app_tag_key} = '${each.value.app_name}' GROUP BY InstanceId ORDER BY AVG() DESC"
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
    expression = "SELECT AVG(mem_used_percent) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}' GROUP BY InstanceId ORDER BY AVG() DESC"
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
    expression = "SELECT AVG(disk_used_percent) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}' AND path = '/' GROUP BY InstanceId ORDER BY AVG() DESC"
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
