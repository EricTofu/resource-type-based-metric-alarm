# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
terraform init          # Initialize providers and modules
terraform plan          # Preview changes
terraform apply         # Apply changes
terraform validate      # Validate configuration syntax
terraform fmt -recursive  # Format all .tf files
```

## Architecture

This is a Terraform project that creates CloudWatch metric alarms for 11 AWS resource types using a modular, DRY pattern.

### Data Flow

`variables.tf` (root) defines typed resource lists → `main.tf` instantiates per-module `for_each` loops keyed by project → each `modules/monitor-<type>/` creates alarms for every resource in the list.

### Module Pattern

Every module follows the same structure:
- `variables.tf`: accepts `project`, `resources`, `sns_topic_arns`, and default threshold variables
- `main.tf`: defines `locals` with a `default_severities` map (per-metric severity), data sources to resolve resource IDs from names, and one `aws_cloudwatch_metric_alarm` per metric

Threshold resolution uses a `coalesce()` chain: per-resource override → calculated value (if applicable) → module default variable.

### Alarm Naming & Description

- Name: `{Project}-{ResourceType}-[{ResourceName}]-{MetricName}`
- Description prefix: `[{SEVERITY}]-` followed by the description text

### Severity → SNS Routing

Three severity levels (WARN / ERROR / CRIT) map to distinct SNS topic ARNs via `var.sns_topic_arns`. The CloudFront module uses `var.sns_topic_arns_global` because CloudFront metrics are only available in `us-east-1` (a separate provider alias).

### Special Module Behaviors

- **EC2**: Looks up instance IDs via `data.aws_instance` (Name tag). Memory alarm uses CWAgent namespace — requires CloudWatch Agent installed. A `null_resource` provisioner runs `scripts/check_ec2_mem_metric.sh` to warn if the metric is missing.
- **RDS**: Splits resources into `cluster_resources` vs `standalone_resources`. For clusters, it expands cluster members via `data.aws_rds_cluster`. FreeableMemory and DatabaseConnections thresholds are auto-calculated from instance class RAM using `instance_memory_map`. Aurora Serverless v2 resources set `serverless = true` to get ACUUtilization and ServerlessDatabaseCapacity alarms.
- **ASG**: Requires `desired_capacity` per resource (used to compute the capacity threshold).
- **Lambda**: Requires `timeout_ms` per resource (used to compute the duration threshold). Account-level concurrency alarm is created once, not per-function.
- **CloudFront**: Uses `distribution_id` as the primary key (with optional `name` for alarm naming).

### Adding a New Resource Type

1. Create `modules/monitor-<type>/variables.tf` and `modules/monitor-<type>/main.tf` following the existing module pattern.
2. Add the resource list variable to root `variables.tf`.
3. Add a `module "monitor_<type>"` block to root `main.tf` with a `for_each` keyed by `group.project`.
