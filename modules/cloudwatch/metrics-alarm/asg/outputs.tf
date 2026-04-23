output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.in_service_capacity : "${k}:GroupInServiceInstances" => v.arn }
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.in_service_capacity : "${k}:GroupInServiceInstances" => v.alarm_name }
}
