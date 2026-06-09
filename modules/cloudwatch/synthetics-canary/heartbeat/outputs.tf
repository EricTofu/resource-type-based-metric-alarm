output "canary_arns" {
  description = "Map of canary name → canary ARN."
  value       = { for k, v in aws_synthetics_canary.heartbeat : k => v.arn }
}

output "alarm_arns" {
  description = "Map of canary name → SuccessPercent alarm ARN."
  value       = { for k, v in aws_cloudwatch_metric_alarm.success_percent : k => v.arn }
}

output "alarm_names" {
  description = "Map of canary name → SuccessPercent alarm name."
  value       = { for k, v in aws_cloudwatch_metric_alarm.success_percent : k => v.alarm_name }
}
