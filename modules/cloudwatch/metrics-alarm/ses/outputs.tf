output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all SES alarms."
  value = {
    for k, v in aws_cloudwatch_metric_alarm.bounce_rate : "${k}:Reputation.BounceRate" => v.arn
  }
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all SES alarms."
  value = {
    for k, v in aws_cloudwatch_metric_alarm.bounce_rate : "${k}:Reputation.BounceRate" => v.alarm_name
  }
}