output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all Lambda alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.duration : "${k}:Duration" => v.arn },
    { "account:ClaimedAccountConcurrency" => aws_cloudwatch_metric_alarm.account_concurrency.arn }
  )
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all Lambda alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.duration : "${k}:Duration" => v.alarm_name },
    { "account:ClaimedAccountConcurrency" => aws_cloudwatch_metric_alarm.account_concurrency.alarm_name }
  )
}