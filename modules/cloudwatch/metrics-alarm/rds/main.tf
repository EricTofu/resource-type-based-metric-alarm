locals {
  cluster_resources    = { for res in var.resources : res.name => res if res.is_cluster }
  standalone_resources = { for res in var.resources : res.name => res if !res.is_cluster }

  default_severities = {
    freeable_memory      = "ERROR"
    cpu                  = "ERROR"
    database_connections = "ERROR"
    free_storage         = "ERROR"
    volume_bytes_used    = "ERROR"
    engine_uptime        = "CRIT"
    acu_utilization      = "ERROR"
    serverless_capacity  = "ERROR"
  }

  # RAM in Bytes mapping for common RDS classes
  # Fallback to local.instance_memory_map[class] or use the provided byte threshold
  # 1GB = 1073741824 Bytes
  instance_memory_map = {
    "db.t3.micro"   = 1073741824  # 1GB
    "db.t3.small"   = 2147483648  # 2GB
    "db.t3.medium"  = 4294967296  # 4GB
    "db.t3.large"   = 8589934592  # 8GB
    "db.t4g.micro"  = 1073741824  # 1GB
    "db.t4g.small"  = 2147483648  # 2GB
    "db.t4g.medium" = 4294967296  # 4GB
    "db.t4g.large"  = 8589934592  # 8GB
    "db.m5.large"   = 8589934592  # 8GB
    "db.m5.xlarge"  = 17179869184 # 16GB
    "db.m6g.large"  = 8589934592  # 8GB
    "db.m6g.xlarge" = 17179869184 # 16GB
    "db.r5.large"   = 17179869184 # 16GB
    "db.r5.xlarge"  = 34359738368 # 32GB
    "db.r6g.large"  = 17179869184 # 16GB
    "db.r6g.xlarge" = 34359738368 # 32GB
  }

  # Multipliers to estimate max_connections from RAM (in bytes)
  # Formula: Memory / Multiplier
  engine_max_connections_multiplier = {
    "mysql"             = 12582912 # 12MB per connection
    "postgres"          = 9531392  # ~9.5MB per connection
    "mariadb"           = 12582912
    "aurora-mysql"      = 12582912
    "aurora-postgresql" = 9531392
  }

  # Fallback multiplier if engine not found
  default_engine_multiplier = 10000000 # 10MB as safe default
}

#------------------------------------------------------------------------------
# Data source to get cluster members if is_cluster is true
#------------------------------------------------------------------------------

data "aws_rds_cluster" "this" {
  for_each           = local.cluster_resources
  cluster_identifier = each.value.name
}

locals {
  # Expand cluster members into individual instance configurations
  expanded_cluster_instances = flatten([
    for cluster_name, cluster_data in data.aws_rds_cluster.this : [
      for member in cluster_data.cluster_members : {
        name         = member
        overrides    = local.cluster_resources[cluster_name].overrides
        is_cluster   = true
        serverless   = local.cluster_resources[cluster_name].serverless
        cluster_name = cluster_name
      }
    ]
  ])

  # Combine expanded cluster members with standalone instances
  all_instances_list = concat(
    [for k, v in local.standalone_resources : {
      name         = v.name
      overrides    = v.overrides
      is_cluster   = false
      serverless   = v.serverless
      cluster_name = null
    }],
    local.expanded_cluster_instances
  )

  # Final map of all instances to create alarms for
  all_instances = { for item in local.all_instances_list : item.name => item }
}

#------------------------------------------------------------------------------
# Data source to get RDS instance details (class) for ALL instances
#------------------------------------------------------------------------------

data "aws_db_instance" "this" {
  for_each = local.all_instances

  db_instance_identifier = each.key
}

#------------------------------------------------------------------------------
# FreeableMemory Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  for_each = local.all_instances

  alarm_name = "${var.project}-RDS-[${each.key}]-FreeableMemory"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.freeable_memory)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-FreeableMemory is in ALARM state"
  )}"

  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.freeable_memory_threshold, null), # 1. Use manual byte threshold if provided
    try(local.instance_memory_map[data.aws_db_instance.this[each.key].db_instance_class] *
      coalesce(try(each.value.overrides.freeable_memory_threshold_percent, null), var.default_freeable_memory_threshold_percent) / 100,
    null),                                # 2. Or calculate from RAM % (if class matches map)
    var.default_freeable_memory_threshold # 3. Last fallback to hardcoded default bytes
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.key
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
    ResourceName = each.key
    ClusterName  = each.value.cluster_name
  }
}

#------------------------------------------------------------------------------
# CPUUtilization Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each = local.all_instances

  alarm_name = "${var.project}-RDS-[${each.key}]-CPUUtilization"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.cpu)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-CPUUtilization is in ALARM state"
  )}"

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
    DBInstanceIdentifier = each.key
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
    ResourceName = each.key
    ClusterName  = each.value.cluster_name
  }
}

#------------------------------------------------------------------------------
# DatabaseConnections Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "database_connections" {
  for_each = local.all_instances

  alarm_name = "${var.project}-RDS-[${each.key}]-DatabaseConnections"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.database_connections)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-DatabaseConnections is in ALARM state"
  )}"

  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.database_connections_threshold, null), # 1. Manual byte threshold
    try(
      (local.instance_memory_map[data.aws_db_instance.this[each.key].db_instance_class] /
        coalesce(
          local.engine_max_connections_multiplier[data.aws_db_instance.this[each.key].engine],
          local.default_engine_multiplier
      )) * coalesce(try(each.value.overrides.database_connections_threshold_percent, null), var.default_database_connections_threshold_percent) / 100,
      null
    ),                                         # 2. Calculated from Memory %
    var.default_database_connections_threshold # 3. Default fallback
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.key
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
    ResourceName = each.key
    ClusterName  = each.value.cluster_name
  }
}

#------------------------------------------------------------------------------
# FreeStorageSpace Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "free_storage" {
  for_each = local.all_instances

  alarm_name = "${var.project}-RDS-[${each.key}]-FreeStorageSpace"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.free_storage)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-FreeStorageSpace is in ALARM state"
  )}"

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
    DBInstanceIdentifier = each.key
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
    ResourceName = each.key
    ClusterName  = each.value.cluster_name
  }
}

#------------------------------------------------------------------------------
# EngineUptime Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "engine_uptime" {
  for_each = local.all_instances

  alarm_name = "${var.project}-RDS-[${each.key}]-EngineUptime"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.engine_uptime)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-EngineUptime is in ALARM state"
  )}"

  namespace           = "AWS/RDS"
  metric_name         = "EngineUptime"
  statistic           = "Average"
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.key
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
    ResourceName = each.key
    ClusterName  = each.value.cluster_name
  }
}

#------------------------------------------------------------------------------
# VolumeBytesUsed Alarm (Aurora Cluster level)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "volume_bytes_used" {
  for_each = local.cluster_resources

  alarm_name = "${var.project}-RDS-[${each.key}]-VolumeBytesUsed"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.volume_bytes_used)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-VolumeBytesUsed is in ALARM state"
  )}"

  namespace           = "AWS/RDS"
  metric_name         = "VolumeBytesUsed"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.volume_bytes_used_threshold, null),
    var.default_volume_bytes_used_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBClusterIdentifier = each.key
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.volume_bytes_used
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "RDS/Aurora"
    ResourceName = each.key
  }
}

#------------------------------------------------------------------------------
# ACUUtilization Alarm (Aurora Serverless v2)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "acu_utilization" {
  for_each = { for k, v in local.all_instances : k => v if v.serverless }

  alarm_name = "${var.project}-RDS-[${each.key}]-ACUUtilization"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.acu_utilization)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-ACUUtilization is in ALARM state"
  )}"

  namespace           = "AWS/RDS"
  metric_name         = "ACUUtilization"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.acu_utilization_threshold, null),
    var.default_acu_utilization_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.key
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.acu_utilization
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "RDS"
    ResourceName = each.key
    ClusterName  = each.value.cluster_name
  }
}

#------------------------------------------------------------------------------
# ServerlessDatabaseCapacity Alarm (Aurora Serverless v2)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "serverless_capacity" {
  for_each = { for k, v in local.all_instances : k => v if v.serverless }

  alarm_name = "${var.project}-RDS-[${each.key}]-ServerlessDatabaseCapacity"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.serverless_capacity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-RDS-[${each.key}]-ServerlessDatabaseCapacity is in ALARM state"
  )}"

  namespace           = "AWS/RDS"
  metric_name         = "ServerlessDatabaseCapacity"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.serverless_capacity_threshold, null),
    var.default_serverless_capacity_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DBInstanceIdentifier = each.key
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.serverless_capacity
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "RDS"
    ResourceName = each.key
    ClusterName  = each.value.cluster_name
  }
}
