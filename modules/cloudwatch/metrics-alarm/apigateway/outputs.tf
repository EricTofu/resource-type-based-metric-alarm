output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all API Gateway alarms."
  value = {
    for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5XXError" => v.arn
  }
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all API Gateway alarms."
  value = {
    for k, v in aws_cloudwatch_metric_alarm.error_5xx : "${k}:5XXError" => v.alarm_name
  }
}