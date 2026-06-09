output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.duration : "${k}:Duration" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.errors : "${k}:Errors" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.throttles : "${k}:Throttles" => v.arn },
    length(aws_cloudwatch_metric_alarm.concurrency) > 0 ? { "account:ClaimedAccountConcurrency" = aws_cloudwatch_metric_alarm.concurrency[0].arn } : {}
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.duration : "${k}:Duration" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.errors : "${k}:Errors" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.throttles : "${k}:Throttles" => v.alarm_name },
    length(aws_cloudwatch_metric_alarm.concurrency) > 0 ? { "account:ClaimedAccountConcurrency" = aws_cloudwatch_metric_alarm.concurrency[0].alarm_name } : {}
  )
}
