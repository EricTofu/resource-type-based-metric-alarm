output "alarm_arns" {
  description = "Map of <resource-key>:<metric-id> to alarm ARN for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.throughput_util : "${k}:throughput_util" => v.arn }
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-id> to alarm name for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.throughput_util : "${k}:throughput_util" => v.alarm_name }
}
