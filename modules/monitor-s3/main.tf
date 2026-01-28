locals {
  s3_resources = { for res in var.resources : res.name => res }

  # Filter resources with replication enabled
  s3_replication_resources = {
    for name, res in local.s3_resources : name => res
    if try(res.overrides.replication_enabled, false)
  }

  default_severity = "WARN"
}

#------------------------------------------------------------------------------
# 5xxErrors Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "error_5xx" {
  for_each = local.s3_resources

  alarm_name = "${var.project}-S3-[${each.value.name}]-5xxErrors"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-S3-[${each.value.name}]-5xxErrors is in ALARM state"
  )}"

  namespace           = "AWS/S3"
  metric_name         = "5xxErrors"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.error_5xx_threshold, null),
    var.default_5xx_error_threshold
  )
  evaluation_periods  = 15
  datapoints_to_alarm = 15
  period              = 60

  dimensions = {
    BucketName = each.value.name
    FilterId   = "EntireBucket"
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severity
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "S3"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# OperationsFailedReplication Alarm (only for buckets with replication enabled)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "replication_failed" {
  for_each = local.s3_replication_resources

  alarm_name = "${var.project}-S3-[${each.value.name}]-OperationsFailedReplication"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-S3-[${each.value.name}]-OperationsFailedReplication is in ALARM state"
  )}"

  namespace           = "AWS/S3"
  metric_name         = "OperationsFailedReplication"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    SourceBucket = each.value.name
    RuleId       = "EntireBucket"
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severity
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "S3"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# Check for S3 Request Metrics
#------------------------------------------------------------------------------

resource "null_resource" "check_s3_metrics" {
  for_each = local.s3_resources

  triggers = {
    bucket_name = each.value.name
  }

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/check_s3_metrics.sh ${data.aws_region.current.name} ${each.value.name}"
  }
}

data "aws_region" "current" {}
