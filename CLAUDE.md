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

This project creates CloudWatch metric alarms for 13 AWS resource types using a modular, DRY pattern split across three layers:

1. **Library modules** (`modules/cloudwatch/metrics-alarm/<type>/`) — reusable alarm definitions, no state
2. **Platform stacks** (`stacks/platform/<env>/`) — SNS topics per account, state in Ops bucket
3. **Project stacks** (`stacks/projects/<project>/<env>/`) — call library modules, read SNS ARNs and the foundation `accounts` map from platform via `terraform_remote_state`

### Data Flow

`stacks/projects/<project>/<env>/terraform.tfvars` → `main.tf` calls library modules directly with `count = length(var.<type>_resources) > 0 ? 1 : 0` → SNS ARNs come from `data.terraform_remote_state.platform.outputs.sns_topic_arns`. There is no root Terraform configuration — every `terraform` command runs inside a stack directory (the legacy monolithic root was removed at M4).

### Module Pattern

Every library module follows the same structure:
- `variables.tf`: accepts `project`, `env`, `resources`, `sns_topic_arns`, `common_tags`, and default threshold variables. The `resources` input (including per-resource `overrides`) and `sns_topic_arns` have `validation {}` blocks.
- `main.tf`: defines `locals` with a `default_severities` map (per-metric severity), data sources to resolve resource IDs from names, and one `aws_cloudwatch_metric_alarm` per metric
- `outputs.tf`: exports `alarm_arns` and `alarm_names` maps keyed by `"<resource-key>:<metric-name>"`

Threshold resolution uses a `coalesce()` chain: per-resource override → calculated value (if applicable) → module default variable.

`overrides.disabled_alarms` is an optional `set(string)` of metric IDs to skip for a resource (opt-out; default `[]` = all metrics on). Each alarm's `for_each` filters out resources whose `disabled_alarms` contains its metric ID, so no alarm is created (no cost, not just muted). Valid IDs are the labels of the module's *active* `aws_cloudwatch_metric_alarm` resources, enforced by a `validation {}` block; commented-out alarms (e.g. ALB `target_response_time`, CloudFront `error_4xx`/`cache_hit_rate`, RDS `volume_bytes_used`) are excluded. Two exceptions: S3 replication is gated by `overrides.replication_enabled` (opt-in, not `disabled_alarms`), and the Lambda account-level concurrency alarm is gated by the module input `concurrency_alarm_enabled`.

### Alarm Naming & Description

- Name: `{Project}-{Env}-{ResourceType}-[{ResourceName}]-{MetricName}`. Project-first matches the `stacks/projects/<project>/<env>/` layout; env follows it (each env is its own account, so env is for cross-account dashboards / payloads, not in-account grouping). Each module builds `{Project}-{Env}-{ResourceType}` once as `local.name_prefix` (from `var.project` + `var.env`) and reuses it for both `alarm_name` and the description fallback — change the convention there, not per-alarm.
- Description prefix: `[{SEVERITY}]-` followed by the description text

### Severity → SNS Routing

Three severity levels (WARN / ERROR / CRIT) map to distinct SNS topic ARNs via `var.sns_topic_arns`. The CloudFront module uses `var.sns_topic_arns_global` because CloudFront metrics are only available in `us-east-1` (a separate provider alias).

### Special Module Behaviors

- **ALB**: Requires `target_groups` (target group names) per resource — UnHealthyHostCount is only published per `(TargetGroup, LoadBalancer)`, so that alarm fans out to one per ALB/target-group pair (keyed `"<alb>:<tg>"`). Omitting `target_groups` is only valid when `unhealthy_host` is in `disabled_alarms`.
- **EC2**: Looks up instance IDs via `data.aws_instance` (Name tag). Memory alarm uses CWAgent namespace — requires CloudWatch Agent installed. A `check {}` block warns at plan time if the Name tag matches zero or multiple instances.
- **RDS**: Uses a flat `resources` list with `is_cluster` and `serverless` flags per entry. For clusters, it expands cluster members via `data.aws_rds_cluster`. FreeableMemory and DatabaseConnections thresholds are auto-calculated from instance class RAM using `instance_memory_map`. Aurora Serverless v2 resources set `serverless = true` to get ACUUtilization and ServerlessDatabaseCapacity alarms. Two alarms are engine-gated via the `data.aws_db_instance` engine: FreeStorageSpace is created only for non-Aurora engines, EngineUptime only for Aurora (each is missing-data=breaching and would be permanently in ALARM on the wrong engine).
- **S3**: The OperationsFailedReplication alarm (gated by `overrides.replication_enabled`) also requires `overrides.replication_destination_bucket`; `overrides.replication_rule_id` defaults to `"EntireBucket"`. The metric only exists per `(SourceBucket, DestinationBucket, RuleId)`.
- **ASG**: Requires `desired_capacity` per resource (used to compute the capacity threshold).
- **Lambda**: Requires `timeout_ms` per resource (used to compute the duration threshold; Errors and Throttles alarms use `default_errors_threshold`/`default_throttles_threshold`, both 1). Account-level concurrency alarm is created once, not per-function.
- **CloudFront**: Uses `distribution_id` as the primary key (with optional `name` for alarm naming).
- **EFS**: Identified by `file_system_id` (`fs-xxxx`) directly — no Name-tag lookup (the AWS provider has no tag-filtered EFS data source). The single `throughput_util` alarm is the repo's only **metric-math** alarm: throughput utilization % = `Sum(MeteredIOBytes)/PERIOD ÷ Average(PermittedThroughput)`. Watched over a long span (default `period=3600` × `evaluation_periods=6` = 6h sustained ≥80%) to catch a creeping throughput-bottleneck trend rather than short spikes; `period`/`evaluation_periods`/`throughput_util_threshold` are overridable. `treat_missing_data="notBreaching"` (idle EFS must not alarm).
- **JMX**: Heap/GC alarms for Java apps on EC2, by Name tag (single `data.aws_instances` lookup; a `check {}` warns on ambiguous Name tags and per-alarm `precondition`s fail the plan with the resource name on a 0/multi match — unlike EC2, which still uses `data.aws_instance`). Depends on the CloudWatch Agent JMX config in `cwagent/jmx/` (contract: namespace `CWAgent`, dimension `InstanceId`, OTel metric names `jvm.*`). `heap_used` = metric-math `100*used/max` (default 85%); `gc_time` = `DIFF(jvm.gc.collections.elapsed)` ms/min (default 6000), read with `stat=Sum` so it totals time-in-GC across the per-collector (`name`-dimension) series that the agent's `aggregation_dimensions: [["InstanceId"]]` rollup collapses server-side. A JVM restart resets the GC counter → negative `DIFF` → never breaches. That `{InstanceId}` rollup is what lets the `{InstanceId}`-only queries match even though the agent appends extra dimensions (ImageId/InstanceType/ProcessGroupName); `Sum` is correct while JMX collects at 60s (= the alarm period; pinned via `metrics_collection_interval: 60` in the config).

### Dashboards

`modules/cloudwatch/dashboard/jmx/` builds a per-instance JVM dashboard via `jsonencode` and exposes the body as the `dashboard_json` output; `dashboards/jmx-jvm.json` is an importable one-instance snapshot of the same layout. The cwagent JMX config that feeds it lives in `cwagent/jmx/` (outside the alarm modules — this repo manages alarms/dashboards, not compute).

### Preflight Checks

`scripts/check_ec2_mem_metric.sh`, `scripts/check_asg_metrics.sh`, `scripts/check_s3_metrics.sh`, and `scripts/check_jmx_metrics.sh` verify that prerequisite CloudWatch metrics exist before alarms are applied (the JMX check matters most: both JMX alarms treat missing data as notBreaching, so a host without the cwagent JMX config would otherwise sit green forever). They accept `--tfvars <path>` and are invoked by `.github/workflows/preflight.yml` on PRs that touch `stacks/projects/**/terraform.tfvars`. Requires `PREFLIGHT_READ_ROLE_ARN` GitHub secret (read-only CloudWatch/EC2/S3 IAM role).

To run locally: `scripts/check_ec2_mem_metric.sh --tfvars stacks/projects/<project>/<env>/terraform.tfvars`

### Adding a New Resource Type

1. Create `modules/cloudwatch/metrics-alarm/<type>/variables.tf` and `modules/cloudwatch/metrics-alarm/<type>/main.tf` following the existing module pattern.
2. Add `outputs.tf` exporting `alarm_arns` and `alarm_names`.
3. Add the `<type>_resources` list variable to each project stack `variables.tf` that needs it (mirroring the module's `resources` type, minus defaults the module already applies).
4. Add a `module "<type>_alarms"` block to the stack's `main.tf` with `count = length(var.<type>_resources) > 0 ? 1 : 0`.
5. Add `<type> = try(module.<type>_alarms[0].alarm_arns, {})` (and the `alarm_names` twin) to the stack's `outputs.tf` — remote-state consumers only see alarms that are exported here.
