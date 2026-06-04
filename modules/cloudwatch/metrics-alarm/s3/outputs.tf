output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all S3 alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5xxErrors" => v.arn },
    { for k, v in try(aws_cloudwatch_metric_alarm.replication_failed, {}) : "${k}:ReplicationFailed" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all S3 alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5xxErrors" => v.alarm_name },
    { for k, v in try(aws_cloudwatch_metric_alarm.replication_failed, {}) : "${k}:ReplicationFailed" => v.alarm_name }
  )
}