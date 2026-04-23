output "alarm_arns" {
  description = "Map of alarm key → alarm ARN for all OpenSearch alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.jvm_memory : "${k}:JVMMemoryPressure" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.old_gen_jvm_memory : "${k}:OldGenJVMMemoryPressure" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.free_storage : "${k}:FreeStorageSpace" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of alarm key → alarm name for all OpenSearch alarms."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.jvm_memory : "${k}:JVMMemoryPressure" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.old_gen_jvm_memory : "${k}:OldGenJVMMemoryPressure" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.free_storage : "${k}:FreeStorageSpace" => v.alarm_name }
  )
}