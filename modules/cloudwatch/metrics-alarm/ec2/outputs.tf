output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all EC2 alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.status_check : "${k}:StatusCheckFailed" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.memory : "${k}:mem_used_percent" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all EC2 alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.status_check : "${k}:StatusCheckFailed" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.memory : "${k}:mem_used_percent" => v.alarm_name }
  )
}