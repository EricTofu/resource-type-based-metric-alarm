output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.status_check : "${k}:StatusCheckFailed" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.status_check_ebs : "${k}:StatusCheckFailed_AttachedEBS" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.memory : "${k}:mem_used_percent" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.status_check : "${k}:StatusCheckFailed" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.status_check_ebs : "${k}:StatusCheckFailed_AttachedEBS" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.memory : "${k}:mem_used_percent" => v.alarm_name }
  )
}
