# Resource Type Based Metric Alarms

A modular Terraform project to manage CloudWatch metric alarms for AWS resources, with DRY configuration patterns and per-resource customization capabilities.

## Features

- **11 Monitoring Modules**: ALB, API Gateway, EC2, ASG, Lambda, RDS, S3, CloudFront, ElastiCache, OpenSearch, SES
- **DRY Configuration**: Use `for_each` loops to create alarms from resource lists
- **Severity-based SNS Routing**: WARN/ERROR/CRIT → different SNS topics
- **Per-resource Overrides**: Customize thresholds, severity, and descriptions per resource
- **Project Grouping**: Organize resources by project for clear alarm naming

## Project Structure

```text
.
├── main.tf                          # Root module, instantiates all monitoring modules
├── variables.tf                     # Global variables and resource lists
├── versions.tf                      # Terraform and provider version constraints
├── terraform.tfvars.example         # Example configuration
└── modules/
    ├── monitor-alb/                 # ALB monitoring (4 alarms)
    ├── monitor-apigateway/          # API Gateway monitoring (1 alarm)
    ├── monitor-ec2/                 # EC2 monitoring (4 alarms)
    ├── monitor-asg/                 # ASG monitoring (1 alarm)
    ├── monitor-lambda/              # Lambda monitoring (2 alarms)
    ├── monitor-rds/                 # RDS/Aurora monitoring (5 alarms)
    ├── monitor-s3/                  # S3 monitoring (2 alarms)
    ├── monitor-cloudfront/          # CloudFront monitoring (4 alarms)
    ├── monitor-elasticache/         # ElastiCache monitoring (2 alarms)
    ├── monitor-opensearch/          # OpenSearch monitoring (4 alarms)
    └── monitor-ses/                 # SES monitoring (1 alarm)
```

## Quick Start

1. Copy the example configuration:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your SNS topic ARNs and resources:

   ```hcl
   sns_topic_arns = {
     WARN  = "arn:aws:sns:ap-northeast-1:123456789012:warning-alerts"
     ERROR = "arn:aws:sns:ap-northeast-1:123456789012:error-alerts"
     CRIT  = "arn:aws:sns:ap-northeast-1:123456789012:critical-alerts"
   }
   ```

3. Initialize and apply:

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Configuration

### Resource List Format

Each resource type uses a list grouped by project:

```hcl
ec2_resources = [
  {
    project = "project1"
    resources = [
      { name = "web-server-1" },
      { name = "web-server-2", overrides = { cpu_threshold = 90 } }
    ]
  },
  {
    project = "project2"
    resources = [
      { name = "api-server-1", overrides = { severity = "CRIT" } }
    ]
  }
]
```

### Per-Resource Overrides

Override default values for individual resources:

| Override Field | Description                                 |
| -------------- | ------------------------------------------- |
| `severity`     | Override default severity (WARN/ERROR/CRIT) |
| `description`  | Custom alarm description                    |
| `*_threshold`  | Metric-specific threshold override          |

### Alarm Naming Convention

```text
{Project}-{ResourceType}-{ResourceName}-{MetricName}
```

Example: `project1-EC2-web-server-1-CPUUtilization`

## Metrics by Resource Type

| Resource Type   | Metrics                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------- |
| **ALB**         | HTTPCode_ELB_5XX_Count, HTTPCode_Target_5XX_Count, UnHealthyHostCount, TargetResponseTime (p90) |
| **API Gateway** | 5XXError                                                                                        |
| **EC2**         | StatusCheckFailed, StatusCheckFailed_AttachedEBS, CPUUtilization, mem_used_percent              |
| **ASG**         | GroupInServiceCapacity                                                                          |
| **Lambda**      | Duration (p90), ClaimedAccountConcurrency                                                       |
| **RDS**         | FreeableMemory, CPUUtilization, DatabaseConnections, FreeStorageSpace, EngineUptime             |
| **S3**          | 5xxErrors, OperationsFailedReplication                                                          |
| **ElastiCache** | CPUUtilization, DatabaseMemoryUsagePercentage                                                   |
| **OpenSearch**  | CPUUtilization, JVMMemoryPressure, OldGenJVMMemoryPressure, FreeStorageSpace                    |
| **SES**         | Reputation.BounceRate                                                                           |
| **CloudFront**  | 4xxErrorRate, 5xxErrorRate, OriginLatency, CacheHitRate                                         |

## Requirements

- Terraform >= 1.0
- AWS Provider >= 5.0
- AWS credentials with CloudWatch and resource read permissions

## Credits

Google Antigravity (with Gemini 3 Pro and Claude Opus 4.5)

## License

MIT
