locals {
  name_prefix   = "${var.project}-${var.env}-ASG"
  asg_resources = { for res in var.resources : res.name => res }

  # app_name is the fleet-mode latch: null = legacy dimension alarm only.
  legacy_resources = { for k, v in local.asg_resources : k => v if v.app_name == null }
  fleet_resources  = { for k, v in local.asg_resources : k => v if v.app_name != null }

  default_severities = {
    in_service_capacity = "ERROR"
    cpu                 = "WARN"
    heap_used           = "WARN"
    memory              = "WARN"
    disk                = "WARN"
  }
}

#------------------------------------------------------------------------------
# GroupInServiceCapacity Alarm
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

  # GROUP BY InstanceId: one series per instance; ALARM when ANY series breaches.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    expression  = "SELECT AVG(CPUUtilization) FROM SCHEMA(\"AWS/EC2\", InstanceId) WHERE tag.${var.app_tag_key} = '${each.value.app_name}' GROUP BY InstanceId"
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

resource "aws_cloudwatch_metric_alarm" "fleet_heap_used" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "heap_used")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-jvm.memory.heap.used"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-jvm.memory.heap.used is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  # Byte threshold from the known -Xmx: CloudWatch math cannot divide two
  # GROUP BY series arrays, so the JMX module's 100*used/max ratio is not
  # expressible here.
  threshold = floor(
    coalesce(
      try(each.value.overrides.heap_threshold_pct, null),
      var.default_heap_threshold_pct
    ) * each.value.heap_max_bytes / 100
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    expression = join("", [
      "SELECT AVG(\"jvm.memory.heap.used\") FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'",
      each.value.process_group != null ? " AND ProcessGroupName = '${each.value.process_group}'" : "",
      " GROUP BY InstanceId"
    ])
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.heap_used
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.heap_used
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
  # Heap pressure is fleet_heap_used's job.
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
    expression  = "SELECT AVG(mem_used_percent) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}' GROUP BY InstanceId"
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
    expression  = "SELECT AVG(disk_used_percent) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}' AND path = '/' GROUP BY InstanceId"
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
