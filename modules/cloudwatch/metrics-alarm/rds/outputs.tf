output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.freeable_memory : "${k}:FreeableMemory" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.database_connections : "${k}:DatabaseConnections" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.free_storage : "${k}:FreeStorageSpace" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.engine_uptime : "${k}:EngineUptime" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.volume_bytes_used : "${k}:VolumeBytesUsed" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.acu_utilization : "${k}:ACUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.serverless_capacity : "${k}:ServerlessDatabaseCapacity" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.freeable_memory : "${k}:FreeableMemory" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.cpu : "${k}:CPUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.database_connections : "${k}:DatabaseConnections" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.free_storage : "${k}:FreeStorageSpace" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.engine_uptime : "${k}:EngineUptime" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.volume_bytes_used : "${k}:VolumeBytesUsed" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.acu_utilization : "${k}:ACUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.serverless_capacity : "${k}:ServerlessDatabaseCapacity" => v.alarm_name }
  )
}
