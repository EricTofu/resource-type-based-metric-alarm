output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:HeapUsedBytes" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:GcTimeMsPerMinute" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:HeapUsedBytes" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:GcTimeMsPerMinute" => v.alarm_name }
  )
}

output "dashboard_targets" {
  description = "Host groups for modules/cloudwatch/dashboard/jmx — pass straight to its `targets` input. Replaces the old `instance_ids` output: the dashboard now uses Metrics Insights and needs no resolved instance IDs."
  value = [
    for k, v in local.jmx_resources : {
      name          = v.name
      app_name      = v.app_name
      process_group = v.process_group
    }
  ]
}
