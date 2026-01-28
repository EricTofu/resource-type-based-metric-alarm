#------------------------------------------------------------------------------
# CloudFront Monitoring Module
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
  # Flatten resources for for_each
  cloudfront_resources = { for res in var.resources : res.distribution_id => res }

  # Default severities per metric
  default_severities = {
    error_4xx      = "WARN"
    error_5xx      = "ERROR"
    origin_latency = "WARN"
    cache_hit_rate = "WARN"
  }
}

#------------------------------------------------------------------------------
# 4xx Error Rate Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "error_4xx" {
  for_each = local.cloudfront_resources

  alarm_name = "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-4xxErrorRate"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.error_4xx)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-4xxErrorRate is in ALARM state"
  )}"

  namespace           = "AWS/CloudFront"
  metric_name         = "4xxErrorRate"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.error_4xx_threshold, null),
    var.default_error_4xx_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DistributionId = each.value.distribution_id
    Region         = "Global"
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.error_4xx
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "CloudFront"
    ResourceName = coalesce(each.value.name, each.value.distribution_id)
  }
}

#------------------------------------------------------------------------------
# 5xx Error Rate Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "error_5xx" {
  for_each = local.cloudfront_resources

  alarm_name = "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-5xxErrorRate"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.error_5xx)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-5xxErrorRate is in ALARM state"
  )}"

  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.error_5xx_threshold, null),
    var.default_error_5xx_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DistributionId = each.value.distribution_id
    Region         = "Global"
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.error_5xx
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "CloudFront"
    ResourceName = coalesce(each.value.name, each.value.distribution_id)
  }
}

#------------------------------------------------------------------------------
# Origin Latency Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "origin_latency" {
  for_each = local.cloudfront_resources

  alarm_name = "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-OriginLatency"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.origin_latency)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-OriginLatency is in ALARM state"
  )}"

  namespace           = "AWS/CloudFront"
  metric_name         = "OriginLatency"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.origin_latency_threshold, null),
    var.default_origin_latency_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DistributionId = each.value.distribution_id
    Region         = "Global"
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.origin_latency
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "CloudFront"
    ResourceName = coalesce(each.value.name, each.value.distribution_id)
  }
}

#------------------------------------------------------------------------------
# Cache Hit Rate Alarm (Low cache hit rate indicates inefficient caching)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cache_hit_rate" {
  for_each = local.cloudfront_resources

  alarm_name = "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-CacheHitRate"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.cache_hit_rate)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-CloudFront-[${coalesce(each.value.name, each.value.distribution_id)}]-CacheHitRate is in ALARM state"
  )}"

  namespace           = "AWS/CloudFront"
  metric_name         = "CacheHitRate"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.cache_hit_rate_threshold, null),
    var.default_cache_hit_rate_threshold
  )
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  period              = 60

  dimensions = {
    DistributionId = each.value.distribution_id
    Region         = "Global"
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.cache_hit_rate
    )]
  ]

  treat_missing_data = "notBreaching"

  tags = {
    Project      = var.project
    ResourceType = "CloudFront"
    ResourceName = coalesce(each.value.name, each.value.distribution_id)
  }
}
