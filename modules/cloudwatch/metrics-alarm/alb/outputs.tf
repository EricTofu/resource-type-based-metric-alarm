output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all ALB alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.http_5xx_elb : "${k}:HTTPCode_ELB_5XX" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.http_5xx_target : "${k}:HTTPCode_Target_5XX" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.unhealthy_host : "${k}:UnHealthyHostCount" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.target_response_time : "${k}:TargetResponseTime" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all ALB alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.http_5xx_elb : "${k}:HTTPCode_ELB_5XX" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.http_5xx_target : "${k}:HTTPCode_Target_5XX" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.unhealthy_host : "${k}:UnHealthyHostCount" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.target_response_time : "${k}:TargetResponseTime" => v.alarm_name }
  )
}