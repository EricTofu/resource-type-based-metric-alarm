# Module Identity Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-identify the JMX module on the CWAgent `AppName` dimension so it works for ASG fleets (where Name tags are duplicated and instance IDs churn), and move `heap_used` out of the ASG module so each module owns one measurement domain.

**Architecture:** Three modules, one identity mechanism each — `ec2` keeps Name-tag lookup for standalone hosts (unchanged), `asg` owns fleet scope via `app_name`, `jmx` becomes `app_name`-only and deletes instance resolution entirely. JVM metrics are renamed to snake_case at the agent so they need no SQL quoting and are addressable from PromQL. The JMX dashboard moves to Metrics Insights widgets, losing its dependency on resolved instance IDs.

**Tech Stack:** Terraform (HCL, AWS provider), bash + python3 (preflight), CWAgent JSON config, CloudWatch Metrics Insights, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-07-30-module-identity-boundaries-design.md` — read it first; it holds the rationale, the verified findings, and the blocking verify items.

## Global Constraints

- Terraform is NOT on the host. Run it via podman from the target directory:
  `podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 <cmd>`
  (image is local; `:Z` is required on Fedora). For the stack, mount the repo root instead — it references `../../../../modules/...`.
- `python3` and `bash` are on the host. There are **no AWS credentials** — test scripts with a stub `aws` on `PATH`, never against a real account.
- Scratchpad for throwaway fixtures:
  `/tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/c8e54910-d1d9-4f68-b36e-718c5325d6da/scratchpad`
- Alarm naming: `{Project}-{Env}-{ResourceType}-[{name}]-{MetricName}` built from `local.name_prefix`; description prefix `[{SEVERITY}]-`; severity ∈ {WARN, ERROR, CRIT} routed via `var.sns_topic_arns[severity]`; both `alarm_actions` and `ok_actions` gated on `each.value.enabled`.
- Outputs keyed `"<resource-key>:<metric-name>"`.
- CWAgent-sourced queries use plain `FROM "CWAgent"`, never `SCHEMA()`. This is verified: plain `FROM` tolerates the extra dimensions agent series carry (`ProcessGroupName`, per-collector `name`), `SCHEMA()` requires an exact match.
- Metrics Insights `WHERE` supports only `=`, `!=`, `AND`. No wildcards.
- Metric math cannot be nested inside a Metrics Insights query. `DIFF(SELECT …)` is a syntax error — the SQL is its own `metric_query` with an id, referenced from a separate expression.
- Terraform idiom: `x == null || trimspace(x) != ""` does **not** work; `||` does not short-circuit and `trimspace(null)` errors. Use `try(trimspace(x), "-") != ""` when null must pass, `try(trimspace(x), "") != ""` when null must fail.
- JVM metric names are snake_case everywhere after Task 1: `jvm_memory_heap_used`, `jvm_memory_heap_max`, `jvm_memory_heap_committed`, `jvm_gc_collections_count`, `jvm_gc_collections_elapsed`, `jvm_threads_count`, `jvm_classes_loaded`.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Branch: `feat/asg-fleet-alarms` (already checked out; do not rebase or switch).
- **Known transient breakage:** Task 3 deletes the JMX module's `instance_ids` output while `stacks/projects/billing/dev/main.tf:156` still consumes it. The stack does not validate from Task 3 until Task 6 fixes the call site. Validate modules only in Tasks 3–5.

---

### Task 1: CWAgent configs — snake_case JVM metric names

**Files:**
- Modify: `cwagent/ec2-java/amazon-cloudwatch-agent-java.json`
- Modify: `cwagent/ec2-java/README.md`
- Modify: `cwagent/jmx/amazon-cloudwatch-agent-jmx.json`
- Modify: `cwagent/jmx/README.md`

**Interfaces:**
- Produces: the metric contract every later task consumes — namespace `CWAgent`, snake_case `jvm_*` names, dimension `AppName` on every plugin, `ProcessGroupName` on `jmx`, `InstanceId` via global `append_dimensions`, 60s interval.

- [ ] **Step 1: Rename the JVM measurements in `cwagent/ec2-java/amazon-cloudwatch-agent-java.json`**

Replace the `jvm.measurement` array (currently a list of dotted strings) with the object form. The `jmx` block becomes:

```json
      "jmx": [
        {
          "endpoint": "<jmx-endpoint>",
          "jvm": {
            "measurement": [
              { "name": "jvm.classes.loaded",          "rename": "jvm_classes_loaded" },
              { "name": "jvm.gc.collections.count",    "rename": "jvm_gc_collections_count" },
              { "name": "jvm.gc.collections.elapsed",  "rename": "jvm_gc_collections_elapsed" },
              { "name": "jvm.memory.heap.committed",   "rename": "jvm_memory_heap_committed" },
              { "name": "jvm.memory.heap.max",         "rename": "jvm_memory_heap_max" },
              { "name": "jvm.memory.heap.used",        "rename": "jvm_memory_heap_used" },
              { "name": "jvm.memory.nonheap.committed","rename": "jvm_memory_nonheap_committed" },
              { "name": "jvm.memory.nonheap.max",      "rename": "jvm_memory_nonheap_max" },
              { "name": "jvm.memory.nonheap.used",     "rename": "jvm_memory_nonheap_used" },
              { "name": "jvm.threads.count",           "rename": "jvm_threads_count" }
            ]
          },
          "append_dimensions": {
            "ProcessGroupName": "<process-group>",
            "AppName": "<app-name>"
          }
        }
      ],
```

Note the `endpoint` placeholder also changes from `<jmx-endpoint e.g. localhost:9999>` to `<jmx-endpoint>` — the old form contains spaces and prose, so a scripted `sed` substitution pass silently misses it. Keep the example in the README table only.

Leave every other plugin (`cpu`, `mem`, `disk`, `net`, `diskio`, `swap`, `netstat`, `processes`, `ethtool`), the `logs` block, `namespace`, `append_dimensions` and `aggregation_dimensions` exactly as they are.

- [ ] **Step 2: Apply the same rename to `cwagent/jmx/amazon-cloudwatch-agent-jmx.json`**

That file's `jvm.measurement` array lists seven dotted names. Convert each to the `{name, rename}` form using the same mapping as Step 1 (it has no `nonheap` entries). Leave `metrics_collection_interval: 60`, `namespace`, `append_dimensions` and `aggregation_dimensions` untouched.

- [ ] **Step 3: Verify both files are valid JSON with placeholders substituted**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm

sed -e 's/<app-name>/live/g' -e 's/<process-group>/chat-server-tomcat/g' \
    -e 's|<jmx-endpoint>|localhost:9999|g' \
    -e 's|<app-log-path>|/apps/x/logs/app.log|g' -e 's|<log-group>|/live/apps/x/logs/|g' \
    cwagent/ec2-java/amazon-cloudwatch-agent-java.json | python3 -m json.tool > /dev/null && echo "ec2-java VALID"

python3 -m json.tool < cwagent/jmx/amazon-cloudwatch-agent-jmx.json > /dev/null && echo "jmx VALID"
```

Expected: `ec2-java VALID` and `jmx VALID`.

- [ ] **Step 4: Confirm no dotted JVM name survives in either config**

```bash
grep -n 'jvm\.' cwagent/ec2-java/amazon-cloudwatch-agent-java.json cwagent/jmx/amazon-cloudwatch-agent-jmx.json
```

Expected: only `"name": "jvm.…"` lines (the left-hand side of each rename). No dotted name may appear anywhere else — in particular not as a bare array element.

- [ ] **Step 5: Update `cwagent/ec2-java/README.md`**

Two edits.

Replace the `<jmx-endpoint e.g. localhost:9999>` row of the placeholder table with:

```markdown
| `<jmx-endpoint>` | JMX RMI endpoint the JVM exposes. The Java process must be started with JMX remote enabled on this port. | `localhost:9999` |
```

In the "Contract (floor, not ceiling)" list, replace the OTel-names bullet with:

```markdown
- JVM metric names are **snake_case**, renamed at the agent from the OTel dotted
  names (`jvm.memory.heap.used` → `jvm_memory_heap_used`). Dots are not valid in
  PromQL metric names and require double-quoting in Metrics Insights SQL; the
  snake_case form also matches every other CWAgent metric (`mem_used_percent`,
  `disk_used_percent`). Renaming produces **new series** — historical data stays
  under the old names.
- `aggregation_dimensions [["InstanceId"], ["InstanceId", "path"]]`: the
  `[InstanceId]` rollup feeds the EC2 `memory` alarm, `[InstanceId, path]` the
  EC2 `disk` alarm. The JMX module no longer needs a rollup — it queries the
  full-dimension series by `AppName`.
```

Then add a migration subsection at the end of the README:

```markdown
## Migrating a host group to the renamed metrics

Order matters — getting it wrong leaves alarms silently green, which is the
failure class the preflight checks exist to catch.

1. Update the Parameter Store parameter from this template (`AppName` on every
   plugin, snake_case `jvm_*` names) and restart the agent.
2. Old-name series stop being written at step 1. Any alarm still referencing a
   dotted name goes `INSUFFICIENT_DATA` until step 4 replaces it.
3. Wait for data, then verify with
   `scripts/check_jmx_metrics.sh --tfvars <path>`. Metrics Insights only sees
   metrics that received data in roughly the last 3 hours — a renamed metric
   appears in `list-metrics` immediately but returns empty values until
   datapoints accumulate. `list-metrics --recently-active PT3H` is the
   matching diagnostic.
4. Apply the Terraform change (JMX entries gain `app_name` and
   `heap_max_bytes`; ASG entries drop the heap fields).
```

- [ ] **Step 6: Update `cwagent/jmx/README.md`**

Add this block immediately after the document's first heading:

```markdown
> **Superseded by `cwagent/ec2-java/`.** This config appends only `InstanceId`
> and no `AppName`, so hosts running it cannot be monitored by the JMX alarm
> module, which is `AppName`-scoped. Migrate Java hosts to
> `cwagent/ec2-java/`. Kept for reference and for the metric-name contract.
```

Then apply the snake_case rename to any metric name this README quotes, so it matches the JSON beside it.

- [ ] **Step 7: Commit**

```bash
git add cwagent/
git commit -m "feat(cwagent): rename JVM metrics to snake_case; supersede cwagent/jmx

Dots are invalid in PromQL metric names and need double-quoting in Metrics
Insights SQL. snake_case also matches every other CWAgent metric. Renaming
creates new series; historical data stays under the old names.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: JMX module interface (`variables.tf`)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/jmx/variables.tf`

**Interfaces:**
- Produces: `var.resources` entries with `name` (label), required `app_name`, `heap_max_bytes`, `process_group`, `enabled`, and `overrides.{severity, description, heap_threshold, gc_time_threshold_ms, disabled_alarms}`. `var.default_heap_threshold` (85) and `var.default_gc_time_threshold_ms` (6000) keep their names and values. Task 3's `main.tf` consumes exactly these names.

- [ ] **Step 1: Replace the `resources` variable**

Replace the whole `variable "resources"` block in `modules/cloudwatch/metrics-alarm/jmx/variables.tf` with:

```hcl
variable "resources" {
  description = "Java host groups to monitor, identified by the CWAgent AppName dimension (see cwagent/ec2-java/). One entry may cover several instances — ASG fleet members, or interchangeable standalone hosts sharing an AppName — because alarms fan out per InstanceId at evaluation time. `name` is a label for alarm naming and output keys only; it is NOT a Name-tag lookup."
  type = list(object({
    name           = string
    app_name       = string
    heap_max_bytes = optional(number)
    process_group  = optional(string)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity             = optional(string)
      description          = optional(string)
      heap_threshold       = optional(number)
      gc_time_threshold_ms = optional(number)
      disabled_alarms      = optional(set(string), [])
    }), {})
  }))
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.severity, null) == null
      || try(contains(["WARN", "ERROR", "CRIT"], r.overrides.severity), false)
    ])
    error_message = "overrides.severity must be one of WARN, ERROR, CRIT (case-sensitive) or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.heap_threshold, null) == null
      || (coalesce(try(r.overrides.heap_threshold, null), 0) >= 0 && coalesce(try(r.overrides.heap_threshold, null), 0) <= 100)
    ])
    error_message = "overrides.heap_threshold must be between 0 and 100 inclusive, or omitted. It is a percentage of heap_max_bytes."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.gc_time_threshold_ms, null) == null
      || coalesce(try(r.overrides.gc_time_threshold_ms, null), 0) >= 0
    ])
    error_message = "overrides.gc_time_threshold_ms must be >= 0, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) : contains(["heap_used", "gc_time"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: heap_used, gc_time"
  }
  # try(...,"") makes null fail: app_name is the identity and cannot be inferred.
  validation {
    condition     = alltrue([for r in var.resources : try(trimspace(r.app_name), "") != ""])
    error_message = "app_name must be a non-empty string — the CWAgent AppName dimension value that identifies this host group."
  }
  validation {
    condition     = length([for r in var.resources : r.app_name]) == length(distinct([for r in var.resources : r.app_name]))
    error_message = "app_name values must be unique across entries (one AppName = one host group)."
  }
  # try(...,"-") makes null pass: process_group is optional.
  validation {
    condition     = alltrue([for r in var.resources : try(trimspace(r.process_group), "-") != ""])
    error_message = "process_group must be a non-empty string when set, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      contains(try(r.overrides.disabled_alarms, []), "heap_used")
      || (r.heap_max_bytes != null && coalesce(r.heap_max_bytes, 0) > 0)
    ])
    error_message = "heap_max_bytes (> 0, the JVM -Xmx in bytes) is required unless heap_used is in disabled_alarms — the heap alarm is a byte threshold, because CloudWatch math cannot divide two GROUP BY series arrays."
  }
}
```

- [ ] **Step 2: Update the two default-threshold descriptions**

`default_heap_threshold` and `default_gc_time_threshold_ms` keep their names, types and values. Only the descriptions change, because the metric names and the heap computation changed:

```hcl
variable "default_heap_threshold" {
  description = "Default JVM heap threshold as a percent of each entry's heap_max_bytes. Rendered into a byte threshold on jvm_memory_heap_used."
  type        = number
  default     = 85
}

variable "default_gc_time_threshold_ms" {
  description = "Default threshold (milliseconds of GC per minute) for DIFF of jvm_gc_collections_elapsed"
  type        = number
  default     = 6000
}
```

- [ ] **Step 3: Validate**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: **FAIL**, and this is the correct outcome at this step. `main.tf` still references `each.value.name` for a Name-tag lookup and `local.instance_ids`, which Task 3 removes; the errors must be about `data.aws_instances` / undeclared fields, not about syntax in the block you just wrote. If the error mentions `variables.tf`, fix it before moving on.

- [ ] **Step 4: Exercise the validation rules with a fixture**

Create `<scratchpad>/jmx-validation-check/main.tf` (throwaway root; keep the directory, Task 3 reuses it):

```hcl
provider "aws" {
  region                      = "ap-northeast-1"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  access_key                  = "test"
  secret_key                  = "test"
}

module "jmx" {
  source  = "/work-module"
  project = "p"
  env     = "dev"
  resources = [{
    name     = "bad-entry"
    app_name = "  "
  }]
  sns_topic_arns = {
    WARN  = "arn:aws:sns:ap-northeast-1:111111111111:w"
    ERROR = "arn:aws:sns:ap-northeast-1:111111111111:e"
    CRIT  = "arn:aws:sns:ap-northeast-1:111111111111:c"
  }
}
```

Because `main.tf` is mid-rewrite, run only `terraform validate` on the *variable* rules by pointing the fixture at the module and reading the first error. Variable validation runs before resource graph errors, so the `app_name` message appears:

```bash
cd <scratchpad>/jmx-validation-check
podman run --rm -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/jmx:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/jmx:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: the error names the whitespace-only `app_name` rule. If instead you see only `data.aws_instances` errors, note it in the report and re-run this fixture check at the end of Task 3 — it must pass there.

- [ ] **Step 5: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/jmx/variables.tf
git commit -m "feat(jmx): AppName-scoped interface — app_name required, heap_max_bytes byte threshold

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: JMX module alarms (`main.tf`, `outputs.tf`)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/jmx/main.tf`
- Modify: `modules/cloudwatch/metrics-alarm/jmx/outputs.tf`

**Interfaces:**
- Consumes: Task 2's variables exactly as named.
- Produces: `aws_cloudwatch_metric_alarm.heap_used` and `.gc_time` (same resource addresses as today), output keys `"<name>:HeapUsedBytes"` and `"<name>:GcTimeMsPerMinute"`, and a new `dashboard_targets` output that Task 4's dashboard module consumes. The `instance_ids` output is **deleted**.

- [ ] **Step 1: Replace the header comment, `locals`, and delete the lookup**

Replace everything from the top of `main.tf` through the closing brace of the `check "jmx_name_tag_uniqueness"` block (lines 1–56 of the current file) with:

```hcl
#------------------------------------------------------------------------------
# JMX / JVM Monitoring Module
# Alarms on CloudWatch-Agent-emitted JVM metrics via Metrics Insights, scoped by
# the agent's AppName dimension and grouped per InstanceId — so one entry covers
# a whole fleet and membership re-resolves at every evaluation. There is NO
# instance lookup: duplicate Name tags (normal inside an ASG) are irrelevant, and
# CodeDeploy blue/green churn needs no re-apply.
# See cwagent/ec2-java/ for the agent config that produces these metrics.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  name_prefix   = "${var.project}-${var.env}-JMX"
  jmx_resources = { for res in var.resources : res.name => res }

  # Optional extra scope for hosts running more than one JVM. Empty string when
  # unset, so the query strings below concatenate unconditionally.
  pg_filter = {
    for k, v in local.jmx_resources : k =>
    v.process_group != null ? " AND ProcessGroupName = '${v.process_group}'" : ""
  }

  default_severities = {
    heap_used = "WARN"
    gc_time   = "WARN"
  }
}
```

- [ ] **Step 2: Replace the `heap_used` alarm**

Replace the whole `resource "aws_cloudwatch_metric_alarm" "heap_used"` block with:

```hcl
#------------------------------------------------------------------------------
# Heap used (bytes) — byte threshold from the entry's known -Xmx.
# CloudWatch math cannot divide two GROUP BY series arrays elementwise, so the
# old 100*used/max ratio is not expressible per-instance; for a homogeneous
# group with a known -Xmx the byte threshold is equivalent.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "heap_used" {
  for_each = {
    for k, v in local.jmx_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "heap_used")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-HeapUsedBytes"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-HeapUsedBytes is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = floor(
    coalesce(
      try(each.value.overrides.heap_threshold, null),
      var.default_heap_threshold
    ) * each.value.heap_max_bytes / 100
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  # GROUP BY InstanceId: one series per instance; ALARM when ANY series breaches.
  # Plain FROM "CWAgent" (not SCHEMA) tolerates the extra dimensions the JMX
  # receiver adds (per-collector `name`, ProcessGroupName).
  metric_query {
    id          = "q1"
    return_data = true
    period      = 60
    expression  = "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'${local.pg_filter[each.key]} GROUP BY InstanceId"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "JMX"
      ResourceName = each.value.name
    }
  )
}
```

- [ ] **Step 3: Replace the `gc_time` alarm**

Replace the whole `resource "aws_cloudwatch_metric_alarm" "gc_time"` block, and the comment banner above it, with:

```hcl
#------------------------------------------------------------------------------
# GC time (ms per minute) — DIFF of the cumulative jvm_gc_collections_elapsed
# counter. DIFF over a multi-series GROUP BY result returns one series per
# instance (verified); the SQL must be its own query referenced by id, because
# metric math cannot be nested inside a Metrics Insights query.
#
# SELECT SUM totals time-in-GC across the per-collector (`name` dimension)
# series within each instance — the receiver emits one series per garbage
# collector. Correct while JMX collects at 60s = this period (one datapoint per
# period); if the collection interval drops below 60s, revisit (a summed
# cumulative counter would over-count).
#
# A JVM restart resets the counter -> negative DIFF -> never breaches (alarm is
# '>'). Fails safe: misses, never false-fires. The first datapoint of a series
# has no predecessor and produces no value.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "gc_time" {
  for_each = {
    for k, v in local.jmx_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "gc_time")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-GcTimeMsPerMinute"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.gc_time)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-GcTimeMsPerMinute is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.gc_time_threshold_ms, null),
    var.default_gc_time_threshold_ms
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "e1"
    expression  = "DIFF(q1)"
    label       = "GcTimeMsPerMinute"
    return_data = true
  }

  metric_query {
    id          = "q1"
    return_data = false
    period      = 60
    expression  = "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'${local.pg_filter[each.key]} GROUP BY InstanceId"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.gc_time)]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.gc_time)]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "JMX"
      ResourceName = each.value.name
    }
  )
}
```

After this step `main.tf` must contain no `data "aws_instances"`, no `check {`, no `lifecycle {`, no `precondition`, and no `local.instance_ids`.

- [ ] **Step 4: Replace `outputs.tf`**

Replace the full content of `modules/cloudwatch/metrics-alarm/jmx/outputs.tf` with:

```hcl
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
```

- [ ] **Step 5: Validate the module**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Plan-render a fixture and assert the generated queries**

Reuse `<scratchpad>/jmx-validation-check/`. Replace its `resources` with one entry that has `process_group` and one that does not:

```hcl
  resources = [
    {
      name           = "chat-fleet"
      app_name       = "billing-chat-live"
      heap_max_bytes = 12884901888
      process_group  = "chat-server-tomcat"
    },
    {
      name           = "batch-host"
      app_name       = "billing-batch"
      heap_max_bytes = 4294967296
      overrides      = { heap_threshold = 80 }
    }
  ]
```

```bash
cd <scratchpad>/jmx-validation-check
podman run --rm -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/jmx:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/jmx:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 plan -refresh=false
```

Expected: 4 alarms to create. Assert these exact strings appear in the rendered plan:

- `SELECT AVG(jvm_memory_heap_used) FROM "CWAgent" WHERE AppName = 'billing-chat-live' AND ProcessGroupName = 'chat-server-tomcat' GROUP BY InstanceId`
- `SELECT SUM(jvm_gc_collections_elapsed) FROM "CWAgent" WHERE AppName = 'billing-batch' GROUP BY InstanceId` (no `ProcessGroupName` clause)
- heap threshold `10952166604` for `chat-fleet` (floor of 85% × 12884901888)
- heap threshold `3435973836` for `batch-host` (floor of 80% × 4294967296)
- alarm names `p-dev-JMX-[chat-fleet]-HeapUsedBytes` and `p-dev-JMX-[batch-host]-GcTimeMsPerMinute`

- [ ] **Step 7: Re-run the invalid-entry fixture check from Task 2 Step 4**

Temporarily set the fixture's `resources` back to the single `app_name = "  "` entry and confirm `validate` now fails with the `app_name` message (the resource-graph errors that masked it are gone). Then restore the two-entry version from Step 6.

- [ ] **Step 8: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/jmx/main.tf modules/cloudwatch/metrics-alarm/jmx/outputs.tf
git commit -m "feat(jmx): AppName-scoped Metrics Insights alarms; drop instance lookup

Deletes data.aws_instances, the Name-tag check block, both preconditions and the
instance_ids output. Duplicate Name tags (normal inside an ASG) are now
irrelevant and blue/green churn needs no re-apply. heap_used becomes a byte
threshold and is renamed HeapUsedBytes; output keys change accordingly. New
dashboard_targets output replaces instance_ids for the dashboard module.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: JMX dashboard — Metrics Insights widgets

**Files:**
- Modify: `modules/cloudwatch/dashboard/jmx/variables.tf`
- Modify: `modules/cloudwatch/dashboard/jmx/main.tf`
- Modify: `dashboards/jmx-jvm.json`

**Interfaces:**
- Consumes: Task 3's `dashboard_targets` output shape — `list(object({ name = string, app_name = string, process_group = optional(string) }))`.
- Produces: `targets` input variable (replacing `instances`); `dashboard_name` and `dashboard_json` outputs unchanged.

- [ ] **Step 1: Replace the `instances` variable**

In `modules/cloudwatch/dashboard/jmx/variables.tf`, replace the whole `variable "instances"` block with:

```hcl
variable "targets" {
  description = "Java host groups to chart, identified by the CWAgent AppName dimension. Widgets use Metrics Insights grouped by InstanceId, so membership resolves at render time — no instance IDs, and fleet churn needs no apply. Pass modules/cloudwatch/metrics-alarm/jmx's dashboard_targets output."
  type = list(object({
    name          = string
    app_name      = string
    process_group = optional(string)
  }))
  validation {
    condition     = alltrue([for t in var.targets : try(trimspace(t.app_name), "") != ""])
    error_message = "targets[*].app_name must be a non-empty CWAgent AppName dimension value."
  }
  validation {
    condition     = alltrue([for t in var.targets : try(trimspace(t.name), "") != ""])
    error_message = "targets[*].name must be a non-empty label (used in widget titles)."
  }
}
```

`project`, `env` and `region` are unchanged.

- [ ] **Step 2: Replace the `locals` block in `main.tf`**

Replace the header comment and the whole `locals` block (through the `])` and closing `}` before the `resource` block) with:

```hcl
#------------------------------------------------------------------------------
# JVM / JMX CloudWatch dashboard. Body built with jsonencode (single source);
# `dashboard_json` output is the same body for console import (dashboards/jmx-jvm.json).
# Three widgets per host group: heap bytes, GC time/min, threads + classes.
# Every series is a Metrics Insights query GROUP BY InstanceId, so a widget shows
# one line per live instance and follows fleet churn with no Terraform run.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  # Optional extra scope for multi-JVM hosts; empty string when unset.
  pg_filter = {
    for t in var.targets : t.name =>
    t.process_group != null ? " AND ProcessGroupName = '${t.process_group}'" : ""
  }

  widgets = flatten([
    for idx, t in var.targets : [
      {
        type   = "metric"
        x      = 0
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${t.name} — Heap (bytes)"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ id = "q1", label = "Heap used", expression = "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE AppName = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }],
            [{ id = "q2", label = "Heap max", expression = "SELECT MAX(jvm_memory_heap_max) FROM \"CWAgent\" WHERE AppName = '${t.app_name}'${local.pg_filter[t.name]}" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${t.name} — GC time (ms/min)"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ id = "e1", label = "GC time ms/min", expression = "DIFF(q1)" }],
            [{ id = "q1", visible = false, expression = "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }],
            [{ id = "e2", label = "GC cycles/min", yAxis = "right", expression = "DIFF(q2)" }],
            [{ id = "q2", visible = false, expression = "SELECT SUM(jvm_gc_collections_count) FROM \"CWAgent\" WHERE AppName = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${t.name} — Threads & classes"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ id = "q1", label = "Threads", expression = "SELECT AVG(jvm_threads_count) FROM \"CWAgent\" WHERE AppName = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }],
            [{ id = "q2", label = "Classes loaded", yAxis = "right", expression = "SELECT AVG(jvm_classes_loaded) FROM \"CWAgent\" WHERE AppName = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }]
          ]
        }
      }
    ]
  ])
}
```

The `resource "aws_cloudwatch_dashboard" "jmx"` block and `outputs.tf` are unchanged. Note the heap widget drops the old `100*m1/m2` ratio — that math cannot span two `GROUP BY` arrays — and charts used bytes per instance against a single max line.

- [ ] **Step 3: Validate the module**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/dashboard/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Regenerate `dashboards/jmx-jvm.json`**

That file is an importable one-host snapshot of the same layout. Regenerate it by hand from the layout above for a single target — `name = "billing-java-app-1"`, `app_name = "billing-java-app-1"`, no `process_group`, `region = "ap-northeast-1"` — as a JSON object `{"widgets": [ ... ]}` with the three widgets at `y = 0`. Then verify:

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
python3 -m json.tool < dashboards/jmx-jvm.json > /dev/null && echo VALID
grep -c 'jvm\.' dashboards/jmx-jvm.json
```

Expected: `VALID`, and the `grep -c` prints `0` (no dotted metric names left).

- [ ] **Step 5: Commit**

```bash
git add modules/cloudwatch/dashboard/jmx/ dashboards/jmx-jvm.json
git commit -m "feat(dashboard): JVM widgets via Metrics Insights, scoped by AppName

Replaces the `instances` input (resolved instance IDs, deleted with the JMX
module's lookup) with `targets`. Widgets resolve membership at render time and
follow fleet churn with no apply. The heap widget charts bytes: the old
100*used/max ratio cannot span two GROUP BY arrays.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: ASG module — remove `heap_used`

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/asg/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/asg/main.tf`
- Modify: `modules/cloudwatch/metrics-alarm/asg/outputs.tf`

**Interfaces:**
- Produces: fleet alarm IDs reduced to `{in_service_capacity, cpu, memory, disk}`; `heap_max_bytes`, `process_group` and `overrides.heap_threshold_pct` removed from `var.resources`. Task 6's stack variable type mirrors this.

- [ ] **Step 1: Trim `variables.tf`**

In `modules/cloudwatch/metrics-alarm/asg/variables.tf`:

1. In the `resources` object type, delete the `heap_max_bytes` and `process_group` attributes, and delete `heap_threshold_pct` from `overrides`.
2. In the threshold-range validation, change the metric list from `["cpu_threshold", "memory_threshold", "heap_threshold_pct", "disk_threshold"]` to `["cpu_threshold", "memory_threshold", "disk_threshold"]`, and drop `heap_threshold_pct` from its `error_message`.
3. In the `disabled_alarms` validation, change the fleet list from `["in_service_capacity", "cpu", "heap_used", "memory", "disk"]` to `["in_service_capacity", "cpu", "memory", "disk"]`, and update the `error_message` to match.
4. In the fleet-only-fields validation, delete the `r.heap_max_bytes == null`, `r.process_group == null` and `try(r.overrides.heap_threshold_pct, null) == null` conjuncts, and update its `error_message` to name only the surviving fields (`the cpu/memory/disk threshold overrides are fleet-mode fields; set app_name on the entry or remove them`).
5. Delete the whole validation block whose `error_message` begins `Fleet entries must set heap_max_bytes`.
6. Delete `variable "default_heap_threshold_pct"`.

Add this note to the `resources` description so the move is discoverable:

```
JVM heap/GC alarms for these instances live in modules/cloudwatch/metrics-alarm/jmx, keyed by the same app_name.
```

- [ ] **Step 2: Trim `main.tf`**

1. Delete `heap_used = "WARN"` from `local.default_severities`.
2. Delete the whole `resource "aws_cloudwatch_metric_alarm" "fleet_heap_used"` block.

Leave `fleet_in_service_capacity`, `fleet_cpu`, `fleet_memory`, `fleet_disk`, the legacy `in_service_capacity` block, and the MIGRATION FOOTGUN comment untouched.

- [ ] **Step 3: Trim `outputs.tf`**

Delete the `fleet_heap_used` line from both the `alarm_arns` and `alarm_names` merges. Mind the commas — the line before the deleted one must not end with a dangling comma if it becomes the last entry (it does not here; `fleet_memory` and `fleet_disk` follow).

- [ ] **Step 4: Confirm no heap reference survives in the module**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
grep -rn 'heap' modules/cloudwatch/metrics-alarm/asg/
```

Expected: only the pointer sentence added in Step 1. Any other hit is a leftover.

- [ ] **Step 5: Validate**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/asg
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/asg/
git commit -m "refactor(asg): move heap_used to the jmx module

Fleet alarm IDs become {in_service_capacity, cpu, memory, disk}. The ASG module
owns fleet scope; the jmx module owns JVM measurements, keyed by the same
app_name. No AWS impact: the fleet heap alarm was never applied.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Stack wiring and example configs

**Files:**
- Modify: `stacks/projects/billing/dev/variables.tf`
- Modify: `stacks/projects/billing/dev/main.tf:149-157`
- Modify: `stacks/projects/billing/dev/terraform.tfvars.example`
- Modify: `stacks/projects/billing/dev/config.yaml.example`

**Interfaces:**
- Consumes: Task 2's JMX interface, Task 3's `dashboard_targets` output, Task 4's `targets` input, Task 5's trimmed ASG interface.
- Produces: a stack that validates again (it has not since Task 3).

- [ ] **Step 1: Update `jmx_resources` in `variables.tf`**

Replace the whole `variable "jmx_resources"` block with:

```hcl
variable "jmx_resources" {
  description = "Java host groups to monitor, identified by the CWAgent AppName dimension (see cwagent/ec2-java/). One entry covers every instance sharing that AppName — an ASG fleet or interchangeable standalone hosts. `name` is a label only, NOT a Name-tag lookup."
  type = list(object({
    name           = string
    app_name       = string
    heap_max_bytes = optional(number)
    process_group  = optional(string)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity             = optional(string)
      description          = optional(string)
      heap_threshold       = optional(number)
      gc_time_threshold_ms = optional(number)
      disabled_alarms      = optional(set(string), [])
    }), {})
  }))
  default = []
}
```

- [ ] **Step 2: Trim `asg_resources` in `variables.tf`**

Delete the `heap_max_bytes` and `process_group` attributes from the object type, and `heap_threshold_pct` from its `overrides`. Leave everything else, including the description's pointer to the design spec.

- [ ] **Step 3: Fix the dashboard call site in `main.tf`**

Replace this line (currently `main.tf:156`):

```hcl
  instances = [for n, id in module.jmx_alarms[0].instance_ids : { name = n, instance_id = id }]
```

with:

```hcl
  targets = module.jmx_alarms[0].dashboard_targets
```

Leave the module block's `count`, `project`, `env` and `region` arguments unchanged.

- [ ] **Step 4: Rework the examples**

In both `terraform.tfvars.example` and `config.yaml.example`:

1. The `jmx` entries gain `app_name` and `heap_max_bytes` (required), and lose nothing else. Rework the comment above them to say identity is `AppName`, not the Name tag.
2. The `asg` fleet entry loses `heap_max_bytes`, `process_group` and `overrides.heap_threshold_pct`.
3. Add a worked **fleet composition** showing one fleet monitored by two modules under one `app_name`. For `config.yaml.example`:

```yaml
  # A fleet is monitored by TWO modules under one identity: `asg` for capacity and
  # OS metrics, `jmx` for the JVM. Both entries carry the same app_name, which must
  # equal the AppName tag on the instances AND the ASG (asg native-metric queries)
  # and the AppName dimension in the agent config (all CWAgent queries).
  asg:
    - name: billing-chat-fleet
      desired_capacity: 3
      app_name:         billing-chat-live
      overrides:
        cpu_threshold:   90
        disk_threshold:  80
        disabled_alarms: [memory]

  # valid jmx ids: heap_used, gc_time. heap_max_bytes = JVM -Xmx in bytes,
  # required unless heap_used is disabled (the alarm is a byte threshold).
  # process_group scopes the queries when a host runs more than one JVM.
  jmx:
    - name: billing-chat-fleet
      app_name:       billing-chat-live
      heap_max_bytes: 12884901888        # -Xmx12G
      process_group:  chat-server-tomcat
      overrides:
        gc_time_threshold_ms: 12000
    # standalone Java hosts may share one app_name; the entry then covers all of
    # them, alarming when ANY instance breaches (GROUP BY InstanceId)
    - name: billing-batch-java
      app_name:       billing-batch
      heap_max_bytes: 4294967296         # -Xmx4G
      overrides:
        heap_threshold: 80
```

The same two entries in HCL for `terraform.tfvars.example`, matching that file's existing comment style:

```hcl
# A fleet is monitored by TWO modules under one identity: asg for capacity and OS
# metrics, jmx for the JVM. Both entries carry the same app_name, which must equal
# the AppName tag on the instances AND the ASG (asg native-metric queries) and the
# AppName dimension in the agent config (all CWAgent queries).
asg_resources = [
  {
    name             = "billing-chat-fleet"
    desired_capacity = 3
    app_name         = "billing-chat-live"
    overrides = {
      cpu_threshold   = 90
      disk_threshold  = 80
      disabled_alarms = ["memory"]
    }
  },
]

# valid jmx ids: heap_used, gc_time. heap_max_bytes = JVM -Xmx in bytes, required
# unless heap_used is disabled (the alarm is a byte threshold). process_group
# scopes the queries when a host runs more than one JVM. `name` is a label only.
jmx_resources = [
  {
    name           = "billing-chat-fleet"
    app_name       = "billing-chat-live"
    heap_max_bytes = 12884901888 # -Xmx12G
    process_group  = "chat-server-tomcat"
    overrides = {
      gc_time_threshold_ms = 12000
    }
  },
  # standalone Java hosts may share one app_name; the entry then covers all of
  # them, alarming when ANY instance breaches (GROUP BY InstanceId)
  {
    name           = "billing-batch-java"
    app_name       = "billing-batch"
    heap_max_bytes = 4294967296 # -Xmx4G
    overrides = {
      heap_threshold = 80
    }
  },
]
```

- [ ] **Step 5: Validate the stack**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
podman run --rm -v "$PWD":/repo:Z -w /repo/stacks/projects/billing/dev docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD":/repo:Z -w /repo/stacks/projects/billing/dev docker.io/hashicorp/terraform:1.10 validate
```

Expected: `Success! The configuration is valid.` This is the step that clears the transient breakage introduced in Task 3 — if it still mentions `instance_ids`, Step 3 was missed.

- [ ] **Step 6: Commit**

```bash
git add stacks/projects/billing/dev/
git commit -m "feat(stacks): wire AppName-scoped jmx and the query-based dashboard

jmx_resources gains app_name/heap_max_bytes/process_group; asg_resources loses
the heap fields; the dashboard call site switches from the deleted instance_ids
output to dashboard_targets. Examples show a fleet monitored by asg + jmx under
one app_name.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Preflight scripts

**Files:**
- Modify: `scripts/check_jmx_metrics.sh`
- Modify: `scripts/check_asg_fleet_metrics.sh`

**Interfaces:**
- Consumes: `jmx_resources` entries (`name`, `app_name`, `heap_max_bytes`, `process_group`, `overrides.disabled_alarms`) and `aws_region` from a tfvars file.
- Produces: exit 0 when prerequisites hold or no entries exist, exit 1 otherwise. Needs `cloudwatch:GetMetricData` on the preflight role.

- [ ] **Step 1: Rewrite `scripts/check_jmx_metrics.sh`**

Replace the whole file. It moves from `InstanceId`-based `list-metrics` to the same Metrics Insights `SELECT`s the alarms run — the pattern `check_asg_fleet_metrics.sh` already uses. **Read `scripts/check_asg_fleet_metrics.sh` first and reuse its helpers verbatim** (`insights_latest` with its stderr/exit-status capture and `report_cli_failure`, `check_query`, the brace-depth tfvars parser, the `mktemp` + `trap` handling, and the `heap_max_bytes` arithmetic evaluator using a restricted `ast` walk). Duplicating those helpers is deliberate: these scripts are standalone and run individually from CI.

The new script must:

1. Parse `--tfvars <path>`; error with a usage line if missing or the file does not exist.
2. Extract `aws_region` with the existing single-regex helper.
3. Parse `jmx_resources` with the brace-depth parser, emitting one tab-separated line per entry: `name`, `app_name`, `heap_max_bytes` (`-` when unset, otherwise the `ast`-evaluated integer), `check_heap` (0 when `heap_used` ∈ `disabled_alarms`, else 1), `check_gc` (0 when `gc_time` ∈ `disabled_alarms`, else 1), `process_group` (`-` when unset). Anchor every key regex with `\b` so `name` cannot capture `app_name`. Skip entries with no `app_name` and warn, since `app_name` is now required.
4. Exit 0 with `No jmx_resources found in <path> — skipping.` when the parser yields nothing.
5. Build `PG_FILTER` as `" AND ProcessGroupName = '<pg>'"` when set, empty otherwise, and append it to **every** query below, exactly as the module does.
6. Per entry, run these checks with `period=60` (matching the alarms):
   - when `check_heap` is 1: `SELECT AVG(jvm_memory_heap_used) FROM "CWAgent" WHERE AppName = '<app>'<PG_FILTER> GROUP BY InstanceId`
     hint: `Deploy the cwagent/ec2-java/ config (AppName dimension on the jmx plugin) and expose the JMX endpoint on the JVM.`
   - when `check_gc` is 1: `SELECT SUM(jvm_gc_collections_elapsed) FROM "CWAgent" WHERE AppName = '<app>'<PG_FILTER> GROUP BY InstanceId`
     same hint.
   - when `check_heap` is 1 and `heap_max_bytes` is not `-`: fetch `SELECT MAX(jvm_memory_heap_max) FROM "CWAgent" WHERE AppName = '<app>'<PG_FILTER>` and compare to `heap_max_bytes` within ±10%, warning and failing on a mismatch with the message `heap_max_bytes=<v> but observed jvm_memory_heap_max=<a> (>10% off). Fix tfvars or -Xmx; the heap alarm threshold derives from this.` When the query returns nothing, warn and fail. When `heap_max_bytes` could not be parsed as a literal, print an explicit skip warning and do **not** set the failure flag.
7. Set the failure flag on any warning and `exit "$FAILED"`.

The per-entry loop, written out so the query strings and gating are unambiguous
(`insights_latest`, `check_query` and `report_cli_failure` come verbatim from
`check_asg_fleet_metrics.sh`; `check_query` takes name, label, expression, hint,
period):

```bash
CWAGENT_HINT="Deploy the cwagent/ec2-java/ config (AppName dimension on the jmx plugin) and expose the JMX endpoint on the JVM."

while IFS=$'\t' read -r NAME APP HEAP_MAX CHECK_HEAP CHECK_GC PG; do
  echo "--- JMX entry '$NAME' (AppName=$APP)"

  PG_FILTER=""
  if [[ "$PG" != "-" ]]; then
    PG_FILTER=" AND ProcessGroupName = '$PG'"
  fi

  if [[ "$CHECK_HEAP" == "1" ]]; then
    check_query "$NAME" "jvm_memory_heap_used" \
      "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId" \
      "$CWAGENT_HINT" 60
  fi

  if [[ "$CHECK_GC" == "1" ]]; then
    check_query "$NAME" "jvm_gc_collections_elapsed" \
      "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId" \
      "$CWAGENT_HINT" 60
  fi

  if [[ "$CHECK_HEAP" == "1" && "$HEAP_MAX" != "-" && "$HEAP_MAX" != "?" ]]; then
    ACTUAL_MAX=$(insights_latest \
      "SELECT MAX(jvm_memory_heap_max) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER" 60)
    if [[ -z "$ACTUAL_MAX" ]]; then
      echo "WARNING: [$NAME] jvm_memory_heap_max query returned no data; cannot sanity-check heap_max_bytes=$HEAP_MAX." >&2
      FAILED=1
    else
      WITHIN=$(python3 -c "import sys; a=float(sys.argv[1]); e=float(sys.argv[2]); print(1 if abs(a-e)/e <= 0.10 else 0)" "$ACTUAL_MAX" "$HEAP_MAX")
      if [[ "$WITHIN" == "1" ]]; then
        echo "OK: [$NAME] heap_max_bytes=$HEAP_MAX matches observed jvm_memory_heap_max=$ACTUAL_MAX (±10%)."
      else
        echo "WARNING: [$NAME] heap_max_bytes=$HEAP_MAX but observed jvm_memory_heap_max=$ACTUAL_MAX (>10% off). Fix tfvars or -Xmx; the heap alarm threshold derives from this." >&2
        FAILED=1
      fi
    fi
  elif [[ "$CHECK_HEAP" == "1" && "$HEAP_MAX" == "?" ]]; then
    echo "WARNING: [$NAME] could not parse heap_max_bytes as a literal expression; skipping the heap_max sanity check." >&2
  fi
done <<< "$ENTRIES"
```

The parser emits `?` for a `heap_max_bytes` it cannot evaluate as an integer
literal expression, and `-` when the key is absent — the two cases differ, and
only the absent case is silent. Note `insights_latest` and `check_query` gain a
trailing period argument here; `check_asg_fleet_metrics.sh` already parameterised
period in its own fix round, so copy that signature rather than inventing one.

Header comment must state: the script runs the alarms' real Insights queries; all JMX alarms are `notBreaching`, so a mis-dimensioned host group would sit green forever; it assumes JVM metric names are snake_case per `cwagent/ec2-java/`; it needs `cloudwatch:GetMetricData`.

- [ ] **Step 2: Trim `scripts/check_asg_fleet_metrics.sh`**

1. Delete the heap checks: the `jvm_memory_heap_used` query, the `jvm_memory_heap_max` ±10% reconciliation, and the `check_heap` and `heap_max_bytes` parser fields. That responsibility moved with the alarm — `check_jmx_metrics.sh` owns it now.
2. Delete the `process_group` parser field and `PG_FILTER` (only the heap queries used it).
3. Add an `--app-tag-key <key>` flag defaulting to `AppName`, and use it in the two **native-metric** queries (`GroupInServiceCapacity` on `AWS/AutoScaling`, `CPUUtilization` on `AWS/EC2`) in place of the hardcoded literal, plus in the `describe-instances` tag filter. Leave the CWAgent queries (`mem_used_percent`, `disk_used_percent`) hardcoded to the `AppName` **dimension** — that name is fixed by the agent config and is not the tag key. Comment that distinction at the flag's parse site.
4. Update the header comment: what it checks now, the new flag, and a pointer to `check_jmx_metrics.sh` for JVM metrics.

- [ ] **Step 3: Syntax-check both scripts**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
bash -n scripts/check_jmx_metrics.sh && echo "jmx SYNTAX-OK"
bash -n scripts/check_asg_fleet_metrics.sh && echo "asg SYNTAX-OK"
test -x scripts/check_jmx_metrics.sh && echo "jmx EXECUTABLE"
```

Expected: all three lines print.

- [ ] **Step 4: Test the skip path**

```bash
SCRATCH=/tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/c8e54910-d1d9-4f68-b36e-718c5325d6da/scratchpad
cat > "$SCRATCH/no-jmx.tfvars" <<'EOF'
aws_region = "ap-northeast-1"
jmx_resources = []
EOF
scripts/check_jmx_metrics.sh --tfvars "$SCRATCH/no-jmx.tfvars"; echo "exit=$?"
```

Expected: the skipping message and `exit=0`.

- [ ] **Step 5: Test the parser with a stub `aws`**

```bash
mkdir -p "$SCRATCH/fakebin"
printf '#!/bin/sh\necho "An error occurred (AccessDenied)" >&2\nexit 254\n' > "$SCRATCH/fakebin/aws"
chmod +x "$SCRATCH/fakebin/aws"

cat > "$SCRATCH/jmx.tfvars" <<'EOF'
aws_region = "ap-northeast-1"
jmx_resources = [
  {
    name           = "chat-fleet"
    app_name       = "billing-chat-live"
    heap_max_bytes = 12 * 1024 * 1024 * 1024
    process_group  = "chat-server-tomcat"
  },
  {
    name           = "batch-host"
    app_name       = "billing-batch"
    heap_max_bytes = 4294967296
    overrides      = { disabled_alarms = ["gc_time"] }
  },
]
EOF

PATH="$SCRATCH/fakebin:$PATH" scripts/check_jmx_metrics.sh --tfvars "$SCRATCH/jmx.tfvars" 2>&1 | tee "$SCRATCH/jmx-out.txt"
echo "exit=${PIPESTATUS[0]}"

grep -c "ProcessGroupName = 'chat-server-tomcat'" "$SCRATCH/jmx-out.txt"
grep -c "jvm_gc_collections_elapsed" "$SCRATCH/jmx-out.txt"
grep -ci "GetMetricData" "$SCRATCH/jmx-out.txt"
```

Expected: exit 1 (every AWS call denied); the `ProcessGroupName` clause appears for `chat-fleet` and not for `batch-host`; `jvm_gc_collections_elapsed` appears **once** (only `chat-fleet` — `batch-host` disabled `gc_time`); the AccessDenied path names `GetMetricData` rather than telling the operator to redeploy the agent config. Also confirm `heap_max_bytes` for `chat-fleet` resolved to `12884901888`, not `12` — the tfvars deliberately uses arithmetic.

Note: the queries only appear in output if the script echoes them. If it does not, add the expression to the WARNING line so failures are diagnosable, then re-run.

- [ ] **Step 6: Re-test `check_asg_fleet_metrics.sh` after the trim**

```bash
cat > "$SCRATCH/asg.tfvars" <<'EOF'
aws_region = "ap-northeast-1"
asg_resources = [
  { name = "legacy-asg", desired_capacity = 2 },
  { name = "chat-fleet", desired_capacity = 3, app_name = "billing-chat-live" },
]
EOF
PATH="$SCRATCH/fakebin:$PATH" scripts/check_asg_fleet_metrics.sh --tfvars "$SCRATCH/asg.tfvars" 2>&1 | tee "$SCRATCH/asg-out.txt"
echo "exit=${PIPESTATUS[0]}"
grep -c "jvm" "$SCRATCH/asg-out.txt"
PATH="$SCRATCH/fakebin:$PATH" scripts/check_asg_fleet_metrics.sh --tfvars "$SCRATCH/asg.tfvars" --app-tag-key Service 2>&1 | grep -c "tag.Service"
```

Expected: exit 1 under the stub; `grep -c "jvm"` prints `0` (heap checks are gone); the `--app-tag-key Service` run shows `tag.Service` in the native queries.

- [ ] **Step 7: Commit**

```bash
git add scripts/check_jmx_metrics.sh scripts/check_asg_fleet_metrics.sh
git commit -m "feat(preflight): jmx check via AppName Insights queries; asg check drops heap

check_jmx_metrics.sh runs the alarms' real SELECTs (snake_case metric names,
ProcessGroupName-scoped when set) and reconciles heap_max_bytes against observed
jvm_memory_heap_max. check_asg_fleet_metrics.sh loses the heap checks with the
alarm and gains --app-tag-key instead of hardcoding AppName for native queries.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Documentation and final sweep

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Rewrite the JMX bullet in "Special Module Behaviors"**

Replace the existing `- **JMX**:` bullet with:

```markdown
- **JMX**: Heap/GC alarms for Java apps on EC2, identified by the CloudWatch Agent's `AppName` **dimension** — there is no instance lookup, so duplicate Name tags (normal inside an ASG) are irrelevant and CodeDeploy blue/green churn needs no re-apply. Both alarms are Metrics Insights queries with `GROUP BY InstanceId`, so one entry covers a whole fleet (or several interchangeable standalone hosts sharing an `app_name`) and ALARMs when **any** instance breaches; membership re-resolves at every evaluation. `heap_used` is a **byte** threshold (`heap_threshold` % × `heap_max_bytes`, the JVM `-Xmx`) because CloudWatch math cannot divide two `GROUP BY` series arrays — hence `heap_max_bytes` is required unless `heap_used` is disabled. `gc_time` = `DIFF(q1)` over `SELECT SUM(jvm_gc_collections_elapsed) … GROUP BY InstanceId` (ms/min at `period=60`); `SUM` totals across the per-collector `name` series, and a JVM restart resets the counter → negative `DIFF` → never breaches (fails safe). `process_group` adds `AND ProcessGroupName = …` for hosts running more than one JVM. Depends on `cwagent/ec2-java/` (namespace `CWAgent`, `AppName` + `ProcessGroupName` + `InstanceId` dimensions, snake_case `jvm_*` names, 60s). Both alarms are `notBreaching`; "the host is gone" is the EC2 module's `status_check` or the ASG capacity watchdog, both missing-data=breaching.
```

- [ ] **Step 2: Amend the ASG bullet**

In the ASG bullet, change the fleet alarm list from five alarms to four — `capacity SUM watchdog missing-data=breaching; per-instance CPU/memory-guardrail/disk via GROUP BY InstanceId, missing-data=notBreaching` — delete the `heap_max_bytes` / `heap_threshold_pct` sentence, and append:

```markdown
 JVM heap/GC for fleet instances lives in the **JMX** module, keyed by the same `app_name`.
```

- [ ] **Step 3: Add the identity-carrier note**

After the "Severity → SNS Routing" section, add:

```markdown
### Identity Carriers (EC2 tags vs CWAgent dimensions)

Two independent carriers, easy to conflate:

- **`app_tag_key`** (module var, default `AppName`) is an **EC2/ASG resource tag key**, used by exactly two queries — the ASG module's `in_service_capacity` (`AWS/AutoScaling`, tag on the ASG itself) and `cpu` (`AWS/EC2`, tag on each instance). It requires the account-level "resource tags on telemetry" setting, per account **and** per region.
- **`AppName`** is a **CWAgent dimension**, a literal string in the agent config (`append_dimensions` cannot read arbitrary tags). Every CWAgent-sourced alarm — the ASG module's `memory`/`disk` and all of JMX — matches on this and ignores resource tags entirely.
- The `ec2` module uses neither: it resolves instances by `tag:Name`.

The resource tag, the agent-config dimension value, and the stack's `app_name` must be kept in sync by hand; drift fails silently green for every alarm except capacity. That is why the preflight scripts exercise both a tag-scoped native query and a dimension-scoped CWAgent query.
```

- [ ] **Step 4: Update the Dashboards and Preflight sections**

In the Dashboards paragraph, replace the `modules/cloudwatch/dashboard/jmx/` sentence with one saying widgets are Metrics Insights queries scoped by `AppName` and grouped by `InstanceId`, so content resolves at render time and follows fleet churn; its input is `targets` (from the JMX module's `dashboard_targets` output). Note `cwagent/jmx/` is superseded by `cwagent/ec2-java/`.

In "Preflight Checks", update the ASG-fleet sentence to drop the heap claims, and add one sentence for the rewritten JMX check: it runs the alarms' Insights `SELECT`s by `AppName` (`ProcessGroupName`-scoped when set) and reconciles `heap_max_bytes` against observed `jvm_memory_heap_max` (±10%); it accepts `--app-tag-key` on the ASG-fleet check for native-metric queries.

- [ ] **Step 5: Verify every claim, then sweep**

Every sentence written above must be true of the code as committed. Check each metric name, threshold, default, and file path against the actual files before committing; if any sentence is not supportable, fix the sentence rather than the code, and report it.

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt -recursive -check
grep -rn 'jvm\.' --include='*.tf' --include='*.md' --include='*.json' --include='*.sh' . \
  | grep -v '^./docs/' | grep -v '"name": "jvm\.'
```

Expected: `fmt -check` produces no output. The `grep` must return nothing — every dotted JVM name outside `docs/` (historical specs and plans keep theirs) and outside the rename left-hand sides is a missed reference. If it lists files, fix them and note it in the report.

- [ ] **Step 6: Commit and clean up**

```bash
git add CLAUDE.md
git commit -m "docs: JMX on AppName, identity carriers, query-based JVM dashboard

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"

rm -rf "$SCRATCH/jmx-validation-check" "$SCRATCH/no-jmx.tfvars" "$SCRATCH/jmx.tfvars" \
       "$SCRATCH/asg.tfvars" "$SCRATCH/jmx-out.txt" "$SCRATCH/asg-out.txt" "$SCRATCH/fakebin"
```

---

## Out of scope (do NOT attempt here)

- **Blocking verify items** (work machine, before any real apply): confirm `PutMetricAlarm` accepts `DIFF()` over a multi-series query and that `StateReason` names individual breaching series; confirm resource-tag telemetry covers `AWS/EC2` **and** `AWS/AutoScaling`, survives a blue/green ASG replacement, and how long tag joining lags a new ASG.
- Parameter Store upload of the renamed agent config, JMX port exposure, `AppName` tagging of instances and ASGs, and the "resource tags on telemetry" account setting.
- Wiring `config.yaml` + `yamldecode` into the stacks. `config.yaml.example` remains documentation; the live input is `terraform.tfvars`.
- An `app_name` mode for the `ec2` module.
- Adding `enabled` to the stack's `asg_resources`/`ec2_resources` types (pre-existing gap, tracked separately).
