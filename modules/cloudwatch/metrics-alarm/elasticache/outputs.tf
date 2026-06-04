output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all ElastiCache alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.memory : "${k}:DatabaseMemoryUsagePercentage" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all ElastiCache alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.memory : "${k}:DatabaseMemoryUsagePercentage" => v.alarm_name }
  )
}