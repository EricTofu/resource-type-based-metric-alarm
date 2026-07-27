output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.in_service_capacity : "${k}:GroupInServiceCapacity" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_in_service_capacity : "${k}:GroupInServiceCapacity" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_cpu : "${k}:CPUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_heap_used : "${k}:jvm.memory.heap.used" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_memory : "${k}:mem_used_percent" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_disk : "${k}:disk_used_percent" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.in_service_capacity : "${k}:GroupInServiceCapacity" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_in_service_capacity : "${k}:GroupInServiceCapacity" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_cpu : "${k}:CPUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_heap_used : "${k}:jvm.memory.heap.used" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_memory : "${k}:mem_used_percent" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_disk : "${k}:disk_used_percent" => v.alarm_name }
  )
}
