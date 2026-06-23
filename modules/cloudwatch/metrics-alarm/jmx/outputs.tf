output "alarm_arns" {
  description = "Map of <resource-key>:<metric-id> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:heap_used" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:gc_time" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-id> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:heap_used" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:gc_time" => v.alarm_name }
  )
}
