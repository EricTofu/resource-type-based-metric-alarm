output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:HeapUsedPercent" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:GcTimeMsPerMinute" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:HeapUsedPercent" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:GcTimeMsPerMinute" => v.alarm_name }
  )
}

output "instance_ids" {
  description = "Map of resource name => resolved EC2 InstanceId, for pairing with modules/cloudwatch/dashboard/jmx (instances = [for n, id in ...instance_ids : { name = n, instance_id = id }])."
  value       = local.instance_ids
}
