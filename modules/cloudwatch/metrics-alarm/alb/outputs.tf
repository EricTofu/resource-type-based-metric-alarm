output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.elb_5xx : "${k}:HTTPCode_ELB_5XX_Count" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.target_5xx : "${k}:HTTPCode_Target_5XX_Count" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.unhealthy_host : "${k}:UnHealthyHostCount" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.target_response_time : "${k}:TargetResponseTime" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.elb_5xx : "${k}:HTTPCode_ELB_5XX_Count" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.target_5xx : "${k}:HTTPCode_Target_5XX_Count" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.unhealthy_host : "${k}:UnHealthyHostCount" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.target_response_time : "${k}:TargetResponseTime" => v.alarm_name }
  )
}
