output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all ASG alarms."
  value = {
    for k, v in aws_cloudwatch_metric_alarm.capacity : "${k}:GroupDesiredCapacity" => v.arn
  }
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all ASG alarms."
  value = {
    for k, v in aws_cloudwatch_metric_alarm.capacity : "${k}:GroupDesiredCapacity" => v.alarm_name
  }
}