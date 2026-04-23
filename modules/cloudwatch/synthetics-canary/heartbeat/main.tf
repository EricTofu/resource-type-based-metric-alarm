locals {
  canaries = { for r in var.resources : r.name => r }

  default_severities = {
    success_percent = "ERROR"
  }

  # Canary runtime version — pin to a supported syn-nodejs-puppeteer release.
  canary_runtime_version = "syn-nodejs-puppeteer-9.1"
}

resource "aws_synthetics_canary" "heartbeat" {
  for_each = local.canaries

  name                 = "${var.project}-${each.value.name}"
  artifact_s3_location = "s3://${var.artifacts_bucket}/${var.project}/${each.value.name}/"
  execution_role_arn   = var.execution_role_arn
  runtime_version      = local.canary_runtime_version
  handler              = "pageLoadBlueprint.handler"

  schedule {
    expression          = "rate(${each.value.frequency_minutes} minute${each.value.frequency_minutes == 1 ? "" : "s"})"
    duration_in_seconds = 0  # run indefinitely
  }

  run_config {
    timeout_in_seconds = each.value.timeout_seconds
    environment_variables = {
      URL = each.value.url
    }
  }

  zip_file = data.archive_file.heartbeat_zip[each.key].output_path

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "SyntheticsCanary"
      ResourceName = each.value.name
    }
  )

  start_canary = true
}

# Canonical heartbeat handler — tiny inline file written per canary.
data "archive_file" "heartbeat_zip" {
  for_each    = local.canaries
  type        = "zip"
  output_path = "${path.module}/.build/${each.value.name}.zip"

  source {
    filename = "nodejs/node_modules/pageLoadBlueprint.js"
    content  = <<-EOT
      const synthetics = require('Synthetics');
      const log = require('SyntheticsLogger');
      exports.handler = async function () {
        const url = process.env.URL;
        await synthetics.executeHttpStep('heartbeat', url);
      };
    EOT
  }
}

resource "aws_cloudwatch_metric_alarm" "success_percent" {
  for_each = local.canaries

  alarm_name        = "${var.project}-Synthetics-[${each.value.name}]-SuccessPercent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.success_percent)}]-${coalesce(try(each.value.overrides.description, null), "${var.project}-Synthetics-[${each.value.name}]-SuccessPercent dropped below threshold")}"

  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = coalesce(try(each.value.overrides.success_percent_threshold, null), var.default_success_percent_threshold)
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 300

  dimensions = {
    CanaryName = aws_synthetics_canary.heartbeat[each.key].name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.success_percent)]
  ]

  treat_missing_data = "breaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "SyntheticsCanary"
      ResourceName = each.value.name
    }
  )
}