output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.error_4xx : "${k}:4xxErrorRate" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5xxErrorRate" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.origin_latency : "${k}:OriginLatency" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.cache_hit_rate : "${k}:CacheHitRate" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.error_4xx : "${k}:4xxErrorRate" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5xxErrorRate" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.origin_latency : "${k}:OriginLatency" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.cache_hit_rate : "${k}:CacheHitRate" => v.alarm_name }
  )
}
