# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Per-stack (run from stacks/<path>):
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
terraform validate
terraform fmt -recursive   # run from repo root to format everything

# Library module validation (no backend):
cd modules/cloudwatch/metrics-alarm/<type>
terraform init -backend=false && terraform validate
```

## Architecture

This project creates CloudWatch metric alarms for 11 AWS resource types using a modular, DRY pattern split across three layers:

1. **Library modules** (`modules/cloudwatch/metrics-alarm/<type>/`) — reusable alarm definitions, no state
2. **Platform stacks** (`stacks/platform/<alias>/`) — SNS topics per account, state in Ops bucket
3. **Service stacks** (`stacks/services/<service>/<alias>/`) — call library modules, read SNS ARNs from platform via `terraform_remote_state`

### Data Flow (legacy monolithic root — pre-M4)

`variables.tf` (root) defines typed resource lists → `main.tf` instantiates per-module `for_each` loops keyed by project → each `modules/cloudwatch/metrics-alarm/<type>/` creates alarms for every resource in the list.

### Data Flow (per-service stacks — post-M2)

`stacks/services/<service>/<alias>/terraform.tfvars` → `main.tf` calls library modules directly with `count = length(var.<type>_resources) > 0 ? 1 : 0` → SNS ARNs come from `data.terraform_remote_state.platform.outputs.sns_topic_arns`.

### Module Pattern

Every library module follows the same structure:
- `variables.tf`: accepts `project`, `resources`, `sns_topic_arns`, `common_tags`, and default threshold variables. All inputs have `validation {}` blocks.
- `main.tf`: defines `locals` with a `default_severities` map (per-metric severity), data sources to resolve resource IDs from names, and one `aws_cloudwatch_metric_alarm` per metric
- `outputs.tf`: exports `alarm_arns` and `alarm_names` maps keyed by `"<resource-key>:<metric-name>"`

Threshold resolution uses a `coalesce()` chain: per-resource override → calculated value (if applicable) → module default variable.

### Alarm Naming & Description

- Name: `{Project}-{ResourceType}-[{ResourceName}]-{MetricName}`
- Description prefix: `[{SEVERITY}]-` followed by the description text

### Severity → SNS Routing

Three severity levels (WARN / ERROR / CRIT) map to distinct SNS topic ARNs via `var.sns_topic_arns`. The CloudFront module uses `var.sns_topic_arns_global` because CloudFront metrics are only available in `us-east-1` (a separate provider alias).

### Special Module Behaviors

- **EC2**: Looks up instance IDs via `data.aws_instance` (Name tag). Memory alarm uses CWAgent namespace — requires CloudWatch Agent installed. A `check {}` block warns at plan time if the Name tag matches zero or multiple instances.
- **RDS**: Uses a flat `resources` list with `is_cluster` and `serverless` flags per entry. For clusters, it expands cluster members via `data.aws_rds_cluster`. FreeableMemory and DatabaseConnections thresholds are auto-calculated from instance class RAM using `instance_memory_map`. Aurora Serverless v2 resources set `serverless = true` to get ACUUtilization and ServerlessDatabaseCapacity alarms.
- **ASG**: Requires `desired_capacity` per resource (used to compute the capacity threshold).
- **Lambda**: Requires `timeout_ms` per resource (used to compute the duration threshold). Account-level concurrency alarm is created once, not per-function.
- **CloudFront**: Uses `distribution_id` as the primary key (with optional `name` for alarm naming).

### Preflight Checks

`scripts/check_ec2_mem_metric.sh`, `scripts/check_asg_metrics.sh`, and `scripts/check_s3_metrics.sh` verify that prerequisite CloudWatch metrics exist before alarms are applied. They accept `--tfvars <path>` and are invoked by `.github/workflows/preflight.yml` on PRs that touch `stacks/services/**/terraform.tfvars`. Requires `PREFLIGHT_READ_ROLE_ARN` GitHub secret (read-only CloudWatch/EC2/S3 IAM role).

To run locally: `scripts/check_ec2_mem_metric.sh --tfvars stacks/services/<svc>/<alias>/terraform.tfvars`

### Adding a New Resource Type

1. Create `modules/cloudwatch/metrics-alarm/<type>/variables.tf` and `modules/cloudwatch/metrics-alarm/<type>/main.tf` following the existing module pattern.
2. Add `outputs.tf` exporting `alarm_arns` and `alarm_names`.
3. Add the resource list variable to root `variables.tf` (legacy root) and any service stack `variables.tf` that needs it.
4. Add a `module "monitor_<type>"` block to root `main.tf` with a `for_each` keyed by `group.project`.
