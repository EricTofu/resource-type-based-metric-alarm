locals {
  rds_resources = { for res in var.resources : res.name => res }

  default_severities = {
    freeable_memory      = "ERROR"
    cpu                  = "ERROR"
    database_connections = "ERROR"
    free_storage         = "ERROR"
    engine_uptime        = "CRIT"
  }
}

#------------------------------------------------------------------------------
# FreeableMemory Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  for_each = local.rds_resources

  alarm_name = "${var.project}-RDS-${each.value.name}-FreeableMemory"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-${each.value.name}-FreeableMemory is in ALARM state"
  )

  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.freeable_memory_threshold, null),
    var.default_freeable_memory_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.freeable_memory
    )]
  ]

  treat_missing_data = "breaching"

  tags = {
    Project      = var.project
    ResourceType = "RDS"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# CPUUtilization Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each = local.rds_resources

  alarm_name = "${var.project}-RDS-${each.value.name}-CPUUtilization"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-${each.value.name}-CPUUtilization is in ALARM state"
  )

  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.cpu_threshold, null),
    var.default_cpu_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.value.name
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
    ResourceType = "RDS"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# DatabaseConnections Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "database_connections" {
  for_each = local.rds_resources

  alarm_name = "${var.project}-RDS-${each.value.name}-DatabaseConnections"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-${each.value.name}-DatabaseConnections is in ALARM state"
  )

  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.database_connections_threshold, null),
    var.default_database_connections_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.database_connections
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "RDS"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# FreeStorageSpace Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "free_storage" {
  for_each = local.rds_resources

  alarm_name = "${var.project}-RDS-${each.value.name}-FreeStorageSpace"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-${each.value.name}-FreeStorageSpace is in ALARM state"
  )

  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.free_storage_threshold, null),
    var.default_free_storage_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.free_storage
    )]
  ]

  treat_missing_data = "breaching"

  tags = {
    Project      = var.project
    ResourceType = "RDS"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# EngineUptime Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "engine_uptime" {
  for_each = local.rds_resources

  alarm_name = "${var.project}-RDS-${each.value.name}-EngineUptime"
  alarm_description = coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-${each.value.name}-EngineUptime is in ALARM state"
  )

  namespace           = "AWS/RDS"
  metric_name         = "EngineUptime"
  statistic           = "Average"
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.engine_uptime
    )]
  ]

  treat_missing_data = "breaching"

  tags = {
    Project      = var.project
    ResourceType = "RDS"
    ResourceName = each.value.name
  }
}
