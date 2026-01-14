locals {
  ec2_resources = { for res in var.resources : res.name => res }

  default_severities = {
    status_check     = "ERROR"
    status_check_ebs = "ERROR"
    cpu              = "WARN"
    memory           = "WARN"
  }
}

#------------------------------------------------------------------------------
# Data source to get EC2 instance ID from Name tag
#------------------------------------------------------------------------------

data "aws_instance" "this" {
  for_each = local.ec2_resources

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
# StatusCheckFailed Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "status_check" {
  for_each = local.ec2_resources

  alarm_name = "${var.project}-EC2-${each.value.name}-StatusCheckFailed"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-EC2-${each.value.name}-StatusCheckFailed is in ALARM state"
  )

  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 60

  dimensions = {
    InstanceId = data.aws_instance.this[each.key].id
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.status_check
    )]
  ]

  treat_missing_data = "breaching"

  tags = {
    Project      = var.project
    ResourceType = "EC2"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# StatusCheckFailed_AttachedEBS Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "status_check_ebs" {
  for_each = local.ec2_resources

  alarm_name = "${var.project}-EC2-${each.value.name}-StatusCheckFailed_AttachedEBS"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-EC2-${each.value.name}-StatusCheckFailed_AttachedEBS is in ALARM state"
  )

  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_AttachedEBS"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 60

  dimensions = {
    InstanceId = data.aws_instance.this[each.key].id
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.status_check_ebs
    )]
  ]

  treat_missing_data = "breaching"

  tags = {
    Project      = var.project
    ResourceType = "EC2"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# CPUUtilization Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each = local.ec2_resources

  alarm_name = "${var.project}-EC2-${each.value.name}-CPUUtilization"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-EC2-${each.value.name}-CPUUtilization is in ALARM state"
  )

  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.cpu_threshold, null),
    var.default_cpu_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  period              = 300

  dimensions = {
    InstanceId = data.aws_instance.this[each.key].id
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.cpu
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "EC2"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# mem_used_percent Alarm (CloudWatch Agent metric)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "memory" {
  for_each = local.ec2_resources

  alarm_name = "${var.project}-EC2-${each.value.name}-mem_used_percent"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-EC2-${each.value.name}-mem_used_percent is in ALARM state"
  )

  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.memory_threshold, null),
    var.default_memory_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  period              = 300

  dimensions = {
    InstanceId = data.aws_instance.this[each.key].id
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.memory
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "EC2"
    ResourceName = each.value.name
  }
}
