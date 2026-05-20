mock_provider "aws" {}

variables {
  project = "test"
  sns_topic_arns = {
    WARN  = "arn:aws:sns:us-east-1:123456789012:warn"
    ERROR = "arn:aws:sns:us-east-1:123456789012:error"
    CRIT  = "arn:aws:sns:us-east-1:123456789012:crit"
  }
}

run "all_alarms_by_default" {
  command = plan
  variables {
    resources = [
      { distribution_id = "E123ABC" }
    ]
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.error_5xx) == 1
    error_message = "error_5xx should be created by default"
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.origin_latency) == 1
    error_message = "origin_latency should be created by default"
  }
}

run "disabled_metric_skipped" {
  command = plan
  variables {
    resources = [
      {
        distribution_id = "E123ABC"
        overrides       = { disabled_alarms = ["origin_latency"] }
      }
    ]
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.origin_latency) == 0
    error_message = "origin_latency should be skipped when disabled"
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.error_5xx) == 1
    error_message = "non-disabled alarms should remain"
  }
}

run "bogus_metric_id_rejected" {
  command = plan
  variables {
    resources = [
      {
        distribution_id = "E123ABC"
        overrides       = { disabled_alarms = ["not_a_metric"] }
      }
    ]
  }
  expect_failures = [var.resources]
}
