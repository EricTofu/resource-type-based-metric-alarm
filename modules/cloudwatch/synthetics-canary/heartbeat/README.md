# Synthetics Canary - Heartbeat Module

Creates HTTP heartbeat canaries for endpoint health monitoring.

## Usage

```hcl
module "canary_heartbeat" {
  source = "../../../../modules/cloudwatch/synthetics-canary/heartbeat"

  project            = "billing"
  resources          = [
    {
      name = "api-health"
      url  = "https://api.example.com/health"
      frequency_minutes = 5
      timeout_seconds   = 30
    }
  ]
  sns_topic_arns     = {
    WARN  = "arn:aws:sns:region:account:warn-topic"
    ERROR = "arn:aws:sns:region:account:error-topic"
    CRIT  = "arn:aws:sns:region:account:crit-topic"
  }
  artifacts_bucket   = "my-synthetics-artifacts"
  execution_role_arn = "arn:aws:iam::account:role/CloudWatchSyntheticsRole"
}
```

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| project | Service name | string | - |
| resources | List of canary configs | list(object) | [] |
| sns_topic_arns | Severity → SNS ARN map | object | - |
| artifacts_bucket | S3 bucket for artifacts | string | - |
| execution_role_arn | IAM role for canaries | string | - |
| default_success_percent_threshold | Success % threshold | number | 90 |
| common_tags | Tags to merge | map(string) | {} |

## Outputs

| Name | Description |
|------|-------------|
| canary_arns | Canary name → ARN |
| alarm_arns | Canary name → alarm ARN |
| alarm_names | Canary name → alarm name |

## Runtime Version

Pinned to `syn-nodejs-puppeteer-9.1`. Update deliberately when AWS releases newer versions.

## Adding More Canary Types

This module covers HTTP heartbeat only. Future types (API happy-path, browser flow) will be added as sibling modules under `modules/cloudwatch/synthetics-canary/`.