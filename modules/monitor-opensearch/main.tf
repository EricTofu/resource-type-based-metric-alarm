locals {
  opensearch_resources = { for res in var.resources : res.name => res }

  default_severities = {
    cpu          = "ERROR"
    jvm_memory   = "ERROR"
    old_gen_jvm  = "ERROR"
    free_storage = "WARN"
  }
}

#------------------------------------------------------------------------------
# CPUUtilization Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each = local.opensearch_resources

  alarm_name = "${var.project}-OpenSearch-[${each.value.name}]-CPUUtilization"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-OpenSearch-[${each.value.name}]-CPUUtilization is in ALARM state"
  )

  namespace           = "AWS/ES"
  metric_name         = "CPUUtilization"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold = coalesce(
    try(each.value.overrides.cpu_threshold, null),
    var.default_cpu_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  period              = 300

  dimensions = {
    DomainName = each.value.name
    ClientId   = data.aws_caller_identity.current.account_id
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
    ResourceType = "OpenSearch"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# JVMMemoryPressure Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "jvm_memory" {
  for_each = local.opensearch_resources

  alarm_name = "${var.project}-OpenSearch-[${each.value.name}]-JVMMemoryPressure"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-OpenSearch-[${each.value.name}]-JVMMemoryPressure is in ALARM state"
  )

  namespace           = "AWS/ES"
  metric_name         = "JVMMemoryPressure"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold = coalesce(
    try(each.value.overrides.jvm_memory_threshold, null),
    var.default_jvm_memory_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  period              = 60

  dimensions = {
    DomainName = each.value.name
    ClientId   = data.aws_caller_identity.current.account_id
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.jvm_memory
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "OpenSearch"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# OldGenJVMMemoryPressure Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "old_gen_jvm_memory" {
  for_each = local.opensearch_resources

  alarm_name = "${var.project}-OpenSearch-[${each.value.name}]-OldGenJVMMemoryPressure"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-OpenSearch-[${each.value.name}]-OldGenJVMMemoryPressure is in ALARM state"
  )

  namespace           = "AWS/ES"
  metric_name         = "OldGenJVMMemoryPressure"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold = coalesce(
    try(each.value.overrides.old_gen_jvm_memory_threshold, null),
    var.default_old_gen_jvm_memory_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  period              = 60

  dimensions = {
    DomainName = each.value.name
    ClientId   = data.aws_caller_identity.current.account_id
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.old_gen_jvm
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "OpenSearch"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# FreeStorageSpace Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "free_storage" {
  for_each = local.opensearch_resources

  alarm_name = "${var.project}-OpenSearch-[${each.value.name}]-FreeStorageSpace"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-OpenSearch-[${each.value.name}]-FreeStorageSpace is in ALARM state"
  )

  namespace           = "AWS/ES"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold = coalesce(
    try(each.value.overrides.free_storage_threshold, null),
    var.default_free_storage_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DomainName = each.value.name
    ClientId   = data.aws_caller_identity.current.account_id
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.free_storage
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "OpenSearch"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# Data source for account ID
#------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
