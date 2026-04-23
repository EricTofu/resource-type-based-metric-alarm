output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all CloudFront alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.error_4xx : "${k}:4xxErrorRate" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5xxErrorRate" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.origin_latency : "${k}:OriginLatency" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.cache_hit_rate : "${k}:CacheHitRate" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all CloudFront alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.error_4xx : "${k}:4xxErrorRate" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5xxErrorRate" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.origin_latency : "${k}:OriginLatency" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.cache_hit_rate : "${k}:CacheHitRate" => v.alarm_name }
  )
}