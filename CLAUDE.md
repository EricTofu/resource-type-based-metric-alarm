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

### Identity Carriers (EC2 tags vs CWAgent dimensions)

Two independent carriers, easy to conflate:

- **`app_tag_key`** (module var, default `AppName`) is an **EC2/ASG resource tag key**, used by exactly two queries — the ASG module's `in_service_capacity` (`AWS/AutoScaling`, tag on the ASG itself) and `cpu` (`AWS/EC2`, tag on each instance). It requires the account-level "resource tags on telemetry" setting, per account **and** per region.
- **`AppName`** is a **CWAgent dimension**, a literal string in the agent config (`append_dimensions` cannot read arbitrary tags). Every CWAgent-sourced alarm — the ASG module's `memory`/`disk` and all of JMX — matches on this and ignores resource tags entirely.
- The `ec2` module uses neither: it resolves instances by `tag:Name`.

The resource tag, the agent-config dimension value, and the stack's `app_name` must be kept in sync by hand; drift fails silently green for every alarm except capacity. That is why the preflight scripts exercise both a tag-scoped native query and a dimension-scoped CWAgent query.

### Special Module Behaviors

- **ALB**: Requires `target_groups` (target group names) per resource — UnHealthyHostCount is only published per `(TargetGroup, LoadBalancer)`, so that alarm fans out to one per ALB/target-group pair (keyed `"<alb>:<tg>"`). Omitting `target_groups` is only valid when `unhealthy_host` is in `disabled_alarms`.
- **EC2**: Looks up instance IDs via `data.aws_instance` (Name tag). Memory alarm uses CWAgent namespace — requires CloudWatch Agent installed. A `check {}` block warns at plan time if the Name tag matches zero or multiple instances. A `disk` alarm (`disk_used_percent`, `{InstanceId, path="/"}`) requires the agent's `[InstanceId, path]` rollup from `cwagent/ec2-java/`.
- **RDS**: Uses a flat `resources` list with `is_cluster` and `serverless` flags per entry. For clusters, it expands cluster members via `data.aws_rds_cluster`. FreeableMemory and DatabaseConnections thresholds are auto-calculated from instance class RAM using `instance_memory_map`. Aurora Serverless v2 resources set `serverless = true` to get ACUUtilization and ServerlessDatabaseCapacity alarms. Two alarms are engine-gated via the `data.aws_db_instance` engine: FreeStorageSpace is created only for non-Aurora engines, EngineUptime only for Aurora (each is missing-data=breaching and would be permanently in ALARM on the wrong engine).
- **S3**: The OperationsFailedReplication alarm (gated by `overrides.replication_enabled`) also requires `overrides.replication_destination_bucket`; `overrides.replication_rule_id` defaults to `"EntireBucket"`. The metric only exists per `(SourceBucket, DestinationBucket, RuleId)`.
- **ASG**: Requires `desired_capacity` per resource. Two modes per entry: legacy (no `app_name`) keeps the classic `AutoScalingGroupName`-dimension GroupInServiceCapacity alarm; fleet mode (`app_name` set) targets CodeDeploy-churned ASGs whose instance IDs and ASG-name suffix change every deploy — four `AppName`-scoped Metrics Insights alarms (capacity `SUM` watchdog missing-data=breaching; per-instance CPU/memory-guardrail/disk via `GROUP BY InstanceId`, missing-data=notBreaching) that re-resolve membership at every evaluation, so churn needs no re-apply. OS memory defaults to 90 (guardrail: JVM hosts sit at 75–85% by design; heap_used is the real memory signal). Identity contract: tfvars `app_name` = `AppName` tag on instances+ASG = CWAgent `AppName` dimension (see `cwagent/ec2-java/`); requires the CloudWatch "resource tags on telemetry" account setting for the native-metric queries. `app_name` is validated non-empty — `app_name = ""` would otherwise latch fleet mode and render `WHERE tag.AppName = ''`. JVM heap/GC for fleet instances lives in the **JMX** module, keyed by the same `app_name`.
  - **⚠️ Flipping an existing entry between modes takes TWO applies.** `in_service_capacity` (legacy) and `fleet_in_service_capacity` render the *same* alarm name by design, so adding `app_name` to an entry already in state puts a create and a destroy of that one CloudWatch alarm in a single plan with no dependency edge between them — `PutMetricAlarm` upserts by name and `DeleteAlarms` deletes by name, so if the destroy lands second it silently removes the just-created ERROR-severity capacity watchdog while state claims it exists. Procedure: remove the entry → apply → re-add it with `app_name` → apply (or delete the legacy alarm out-of-band plus `terraform state rm` before the apply that adds `app_name`). Same in reverse when removing `app_name`. A `moved` block cannot express this — it is static and would also move entries that stay legacy. The three per-instance fleet alarm names (CPU/memory/disk) have no legacy counterpart and are unaffected. See the MIGRATION FOOTGUN comment in the module's `main.tf`.
- **Lambda**: Requires `timeout_ms` per resource (used to compute the duration threshold; Errors and Throttles alarms use `default_errors_threshold`/`default_throttles_threshold`, both 1). Account-level concurrency alarm is created once, not per-function.
- **CloudFront**: Uses `distribution_id` as the primary key (with optional `name` for alarm naming).
- **EFS**: Identified by `file_system_id` (`fs-xxxx`) directly — no Name-tag lookup (the AWS provider has no tag-filtered EFS data source). The single `throughput_util` alarm was the repo's first **metric-math** alarm (the JMX module's `heap_used`/`gc_time` are also metric-math): throughput utilization % = `Sum(MeteredIOBytes)/PERIOD ÷ Average(PermittedThroughput)`. Watched over a long span (default `period=3600` × `evaluation_periods=6` = 6h sustained ≥80%) to catch a creeping throughput-bottleneck trend rather than short spikes; `period`/`evaluation_periods`/`throughput_util_threshold` are overridable. `treat_missing_data="notBreaching"` (idle EFS must not alarm).
- **JMX**: Heap/GC alarms for Java apps on EC2, identified by the CloudWatch Agent's `AppName` **dimension** — there is no instance lookup, so duplicate Name tags (normal inside an ASG) are irrelevant and CodeDeploy blue/green churn needs no re-apply. Both alarms are Metrics Insights queries with `GROUP BY InstanceId`, so one entry covers a whole fleet (or several interchangeable standalone hosts sharing an `app_name`) and ALARMs when **any** instance breaches; membership re-resolves at every evaluation. `heap_used` is a **byte** threshold (`heap_threshold` % × `heap_max_bytes`, the JVM `-Xmx`) because CloudWatch math cannot divide two `GROUP BY` series arrays — hence `heap_max_bytes` is required unless `heap_used` is disabled. `gc_time` = `DIFF(q1)` over `SELECT SUM(jvm_gc_collections_elapsed) … GROUP BY InstanceId` (ms/min at `period=60`); `SUM` totals across the per-collector `name` series, and a JVM restart resets the counter → negative `DIFF` → never breaches (fails safe). `process_group` adds `AND ProcessGroupName = …` for hosts running more than one JVM. Depends on `cwagent/ec2-java/` (namespace `CWAgent`, `AppName` + `ProcessGroupName` + `InstanceId` dimensions, snake_case `jvm_*` names, 60s). Both alarms are `notBreaching`; "the host is gone" is the EC2 module's `status_check` or the ASG capacity watchdog, both missing-data=breaching. **Known limitation — one `app_name` covers one JVM per host.** `app_name` is validated unique across entries, so a host running two JVMs cannot get one entry per `process_group`: setting `process_group` alarms a single JVM and leaves the other watched by no module at all, while omitting it makes `AVG(jvm_memory_heap_used) … GROUP BY InstanceId` average both `ProcessGroupName` series against one `heap_max_bytes` — `chat-server-tomcat` (`-Xmx12G`) at 11.9G beside `batch-worker` (`-Xmx2G`) at 0.2G averages to ~6.05G under a `0.85 × 12G = 10.95G` threshold, so the near-OOM JVM never fires (and `gc_time`'s `SUM` conversely adds both JVMs' GC time into one threshold). That is the silently-green class this design exists to remove, accepted only because there are no multi-JVM hosts today; the fix when one appears is to key uniqueness on the `app_name` + `process_group` pair and reject two entries sharing an `app_name` where either omits `process_group`.

### Dashboards

`modules/cloudwatch/dashboard/jmx/` builds the JVM dashboard via `jsonencode` and exposes the body as the `dashboard_json` output. Every widget is a Metrics Insights query scoped by `AppName` and grouped by `InstanceId`, so widget content resolves at render time and follows fleet churn with no Terraform run; its input is `targets` — pass the JMX alarm module's `dashboard_targets` output. `dashboards/jmx-jvm.json` is an importable snapshot of the same layout. `cwagent/jmx/` (dimension `InstanceId` only, no `AppName`) is superseded by `cwagent/ec2-java/`, the full Java-host template (JMX + system metrics, `AppName`/`ProcessGroupName`/`InstanceId` dimensions) both the alarms and this dashboard depend on; its live copies live in SSM Parameter Store, outside the alarm modules — this repo manages alarms/dashboards, not compute.

### Preflight Checks

`scripts/check_ec2_mem_metric.sh`, `scripts/check_asg_metrics.sh`, `scripts/check_asg_fleet_metrics.sh`, `scripts/check_s3_metrics.sh`, and `scripts/check_jmx_metrics.sh` verify that prerequisite CloudWatch metrics exist before alarms are applied (the JMX check matters most: both JMX alarms treat missing data as notBreaching, so a host without the cwagent JMX config would otherwise sit green forever). `check_ec2_mem_metric.sh` covers both CWAgent-fed EC2 alarms: `mem_used_percent` at `{InstanceId}` and `disk_used_percent` at `{InstanceId, path=/}` (the disk series needs the `cwagent/ec2-java/` template; `cwagent/jmx/` does not publish it), skipping per entry on `memory`/`disk` in `disabled_alarms`. `check_asg_metrics.sh` covers **legacy** ASG entries only — it skips entries with `app_name`, whose `name` is a logical label and whose real ASG name churns every deploy. The ASG fleet check (`check_asg_fleet_metrics.sh`) runs the alarms' actual Metrics Insights SELECTs via `get-metric-data`, each at the period of the alarm it mirrors (capacity 60s, per-instance 300s) so printed values are comparable with `desired_capacity` — the capacity and CPU queries prove tag telemetry on `AWS/AutoScaling` and `AWS/EC2` (separate paths) and the CWAgent queries (`mem_used_percent`, `disk_used_percent`) prove the `AppName` series end-to-end. Every per-metric check there honours `disabled_alarms` (`cpu`, `memory`, `disk`), matching `check_ec2_mem_metric.sh`. It needs `cloudwatch:GetMetricData` on the preflight role, and a failed CLI call is reported as an ERROR with the CLI's own message rather than as "no data". It accepts `--app-tag-key` (default `AppName`) for the two native-metric queries (capacity, CPU) and the `describe-instances` tag filter, mirroring the module's `app_tag_key` variable — the CWAgent queries stay hardcoded to the `AppName` dimension, which is fixed by the agent config and is not the tag key. JVM heap prerequisites moved out of this script entirely: the rewritten `check_jmx_metrics.sh` runs the JMX alarms' own Insights SELECTs (`jvm_memory_heap_used`, `jvm_gc_collections_elapsed`, both `GROUP BY InstanceId` and `ProcessGroupName`-scoped when the entry sets `process_group`) and separately reconciles each entry's `heap_max_bytes` (evaluated as a literal int expression, so `12 * 1024 * 1024 * 1024` works) against the observed `jvm_memory_heap_max` (±10%); entries missing `app_name` or `name` are counted as malformed and fail the run rather than being silently skipped. Three properties hold across all five scripts (the two Insights-based ones especially, since a silent pass there is what lets a typo'd `app_name` reach production green): the tfvars parsers strip line comments before their brace/bracket counting, so a commented-out entry is never treated as live and an unbalanced brace inside a comment cannot truncate the list; matching `<var>_resources = [` but extracting no entries is an ERROR + exit 1, with exit 0 reserved for a genuinely absent variable or a literal empty list; and each `GROUP BY InstanceId` result set is read as a set — the first series that actually has a datapoint, plus the series count — never `MetricDataResults[0]`, which can be an instance terminated inside the ~3h Insights lookback but outside the scripts' 1h window. On a no-data result both Insights scripts run `list-metrics --recently-active PT3H` (needs `cloudwatch:ListMetrics`) to separate "metric absent" from "filter matched nothing". They accept `--tfvars <path>` and are invoked by `.github/workflows/preflight.yml` on PRs that touch `stacks/projects/**/terraform.tfvars`. Requires `PREFLIGHT_READ_ROLE_ARN` GitHub secret (read-only CloudWatch/EC2/S3 IAM role).

To run locally: `scripts/check_ec2_mem_metric.sh --tfvars stacks/projects/<project>/<env>/terraform.tfvars`

### Adding a New Resource Type

1. Create `modules/cloudwatch/metrics-alarm/<type>/variables.tf` and `modules/cloudwatch/metrics-alarm/<type>/main.tf` following the existing module pattern.
2. Add `outputs.tf` exporting `alarm_arns` and `alarm_names`.
3. Add the `<type>_resources` list variable to each project stack `variables.tf` that needs it (mirroring the module's `resources` type, minus defaults the module already applies).
4. Add a `module "<type>_alarms"` block to the stack's `main.tf` with `count = length(var.<type>_resources) > 0 ? 1 : 0`.
5. Add `<type> = try(module.<type>_alarms[0].alarm_arns, {})` (and the `alarm_names` twin) to the stack's `outputs.tf` — remote-state consumers only see alarms that are exported here.
