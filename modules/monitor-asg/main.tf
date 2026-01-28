locals {
  asg_resources    = { for res in var.resources : res.name => res }
  default_severity = "ERROR"
}

#------------------------------------------------------------------------------
# GroupInServiceCapacity Alarm
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "in_service_capacity" {
  for_each = local.asg_resources

  alarm_name = "${var.project}-ASG-[${each.value.name}]-GroupInServiceCapacity"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${var.project}-ASG-[${each.value.name}]-GroupInServiceCapacity is in ALARM state"
  )}"

  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceCapacity"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = each.value.desired_capacity
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  period              = 60

  dimensions = {
    AutoScalingGroupName = each.value.name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severity
    )]
  ]

  treat_missing_data = "breaching"

  tags = {
    Project      = var.project
    ResourceType = "ASG"
    ResourceName = each.value.name
  }
}

#------------------------------------------------------------------------------
# Check for ASG metric collection
#------------------------------------------------------------------------------

resource "null_resource" "check_asg_metrics" {
  for_each = local.asg_resources

  triggers = {
    asg_name = each.value.name
  }

  # Using "aws_region" data source would be better, but we don't have it defined in this module
  # We can assume the provider's region. But for simplicity in this script, 
  # we might need to rely on the environment or passed variable.
  # Let's add a data source for current region to be clean.

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/check_asg_metrics.sh ${data.aws_region.current.name} ${each.value.name}"
  }
}

data "aws_region" "current" {}
