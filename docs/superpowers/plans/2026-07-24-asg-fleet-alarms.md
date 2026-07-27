# ASG Fleet Alarms + Java-EC2 CWAgent Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drift-proof CloudWatch alarms for CodeDeploy-churned ASG fleets via AppName-scoped Metrics Insights queries, plus a disk alarm for standalone EC2 and a first-class CWAgent config template for Java hosts.

**Architecture:** The ASG module gains a *fleet mode* per resource entry, latched by an optional `app_name` field: fleet entries get five `metric_query`-based Metrics Insights alarms (capacity watchdog single-series; per-instance CPU/heap/memory/disk via `GROUP BY InstanceId`), legacy entries keep today's dimension alarm untouched. The EC2 module adds one classic `disk_used_percent` alarm. A new `cwagent/ec2-java/` template (reference copy of the Parameter Store config) defines the metric contract both consume. A new preflight script exercises the *actual* Insights queries via `aws cloudwatch get-metric-data` before alarms apply.

**Tech Stack:** Terraform (HCL, AWS provider), bash + python3 (preflight), CWAgent JSON config, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-07-24-asg-fleet-alarms-design.md` — read it first; it holds the rationale and the verify-by-hand items.

## Global Constraints

- Terraform is NOT on the host. Run it via podman from the target directory:
  `podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 <cmd>`
- `python3` IS on the host.
- Alarm naming: `{Project}-{Env}-ASG-[{name}]-{MetricName}` via `local.name_prefix`; description prefix `[{SEVERITY}]-`; severity ∈ {WARN, ERROR, CRIT} routed via `var.sns_topic_arns`.
- Outputs keyed `"<resource-key>:<metric-name>"`.
- The CWAgent identity dimension is literally `AppName`; the EC2/ASG tag key defaults to `AppName` via `var.app_tag_key`. tfvars `app_name` = tag value = dimension value.
- A Terraform alarm resource cannot mix `dimensions` with `metric_query` — fleet and legacy are separate resource blocks.
- Metrics Insights `WHERE` supports only `=`, `!=`, `AND` — never build queries needing wildcards.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Branch: `feat/asg-fleet-alarms` (already exists, rebased onto `fix/efs-jmx-review-fixes` — do not rebase again).

---

### Task 1: ASG module interface (`variables.tf`)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/asg/variables.tf`

**Interfaces:**
- Produces: `var.resources` entries with optional `app_name` (fleet latch), `heap_max_bytes`, `process_group`, new overrides `cpu_threshold`/`memory_threshold`/`heap_threshold_pct`/`disk_threshold`; module vars `app_tag_key` (default `"AppName"`), `default_cpu_threshold` (85), `default_memory_threshold` (90), `default_heap_threshold_pct` (85), `default_disk_threshold` (85). Task 2's `main.tf` consumes exactly these names.

- [ ] **Step 1: Replace the `resources` variable and add the new module-level variables**

Replace the existing `variable "resources"` block in `modules/cloudwatch/metrics-alarm/asg/variables.tf` with:

```hcl
variable "resources" {
  description = "List of ASG resources to monitor. Entries with app_name set use fleet mode (AppName-scoped Metrics Insights alarms); entries without it use legacy mode (AutoScalingGroupName dimension alarm only)."
  type = list(object({
    name             = string
    desired_capacity = number
    app_name         = optional(string)
    heap_max_bytes   = optional(number)
    process_group    = optional(string)
    enabled          = optional(bool, true)
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
      cpu_threshold      = optional(number)
      memory_threshold   = optional(number)
      heap_threshold_pct = optional(number)
      disk_threshold     = optional(number)
      disabled_alarms    = optional(set(string), [])
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
      try(r.overrides.capacity_threshold, null) == null || coalesce(try(r.overrides.capacity_threshold, null), 0) >= 0
    ])
    error_message = "overrides.capacity_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for t in ["cpu_threshold", "memory_threshold", "heap_threshold_pct", "disk_threshold"] :
        try(r.overrides[t], null) == null
        || (coalesce(try(r.overrides[t], null), 0) >= 0 && coalesce(try(r.overrides[t], null), 0) <= 100)
      ])
    ])
    error_message = "overrides.cpu_threshold, memory_threshold, heap_threshold_pct and disk_threshold must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) :
        contains(
          r.app_name == null
          ? ["in_service_capacity"]
          : ["in_service_capacity", "cpu", "heap_used", "memory", "disk"],
          m
        )
      ])
    ])
    error_message = "overrides.disabled_alarms must be a subset of [in_service_capacity] for legacy entries (no app_name) or [in_service_capacity, cpu, heap_used, memory, disk] for fleet entries."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      r.app_name != null || (
        r.heap_max_bytes == null
        && r.process_group == null
        && try(r.overrides.cpu_threshold, null) == null
        && try(r.overrides.memory_threshold, null) == null
        && try(r.overrides.heap_threshold_pct, null) == null
        && try(r.overrides.disk_threshold, null) == null
      )
    ])
    error_message = "heap_max_bytes, process_group and the cpu/memory/heap/disk threshold overrides are fleet-mode fields; set app_name on the entry or remove them."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      r.app_name == null
      || contains(try(r.overrides.disabled_alarms, []), "heap_used")
      || (r.heap_max_bytes != null && coalesce(r.heap_max_bytes, 0) > 0)
    ])
    error_message = "Fleet entries must set heap_max_bytes (> 0, the JVM -Xmx in bytes) unless heap_used is in disabled_alarms."
  }
  validation {
    condition = length([for r in var.resources : r.app_name if r.app_name != null]) == length(distinct([for r in var.resources : r.app_name if r.app_name != null]))
    error_message = "app_name values must be unique across fleet entries (one AppName = one fleet)."
  }
}
```

Then append these module-level variables after the `sns_topic_arns` block (keep `sns_topic_arns` and `common_tags` unchanged):

```hcl
variable "app_tag_key" {
  description = "EC2/ASG resource tag key that carries the fleet identity for tag-scoped Metrics Insights queries. The CWAgent dimension name is always AppName regardless of this value."
  type        = string
  default     = "AppName"
}

#------------------------------------------------------------------------------
# Default Thresholds (fleet mode)
#------------------------------------------------------------------------------

variable "default_cpu_threshold" {
  description = "Default per-instance CPUUtilization threshold (percent) for fleet entries"
  type        = number
  default     = 85
}

variable "default_memory_threshold" {
  description = "Default per-instance mem_used_percent guardrail threshold for fleet entries. Deliberately high: JVM hosts sit at 75-85% by design; this catches off-heap/native leaks and rogue processes, not heap pressure (heap_used does that)."
  type        = number
  default     = 90
}

variable "default_heap_threshold_pct" {
  description = "Default heap_used threshold as a percent of heap_max_bytes for fleet entries"
  type        = number
  default     = 85
}

variable "default_disk_threshold" {
  description = "Default per-instance disk_used_percent threshold for fleet entries (path /)"
  type        = number
  default     = 85
}
```

- [ ] **Step 2: Validate syntax**

```bash
cd modules/cloudwatch/metrics-alarm/asg
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: `Success! The configuration is valid.` (main.tf still compiles because the old fields it references — name, desired_capacity, overrides — all still exist.)

- [ ] **Step 3: Exercise the validation rules with a fixture plan**

Write `/tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad/asg-validation-check/main.tf` (a throwaway root that calls the module with an INVALID entry — legacy entry carrying a fleet field):

```hcl
module "asg" {
  source = "/work-module"
  project = "p"
  env     = "dev"
  resources = [{
    name             = "legacy-asg"
    desired_capacity = 2
    heap_max_bytes   = 12884901888
  }]
  sns_topic_arns = {
    WARN  = "arn:aws:sns:ap-northeast-1:111111111111:w"
    ERROR = "arn:aws:sns:ap-northeast-1:111111111111:e"
    CRIT  = "arn:aws:sns:ap-northeast-1:111111111111:c"
  }
}
```

Run (mounting both the fixture and the module):

```bash
cd /tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad/asg-validation-check
podman run --rm \
  -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/asg:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm \
  -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/asg:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: validate FAILS with the "fleet-mode fields" error message. Then change the fixture entry to a valid legacy entry (delete the `heap_max_bytes` line), re-run validate, and expect `Success!`. Keep the fixture dir — Task 2 reuses it.

- [ ] **Step 4: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/asg/variables.tf
git commit -m "feat(asg): fleet-mode interface — app_name latch, heap/disk/cpu/memory thresholds

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: ASG module fleet alarms (`main.tf`, `outputs.tf`)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/asg/main.tf`
- Modify: `modules/cloudwatch/metrics-alarm/asg/outputs.tf`

**Interfaces:**
- Consumes: Task 1's variables exactly as named.
- Produces: resource blocks `aws_cloudwatch_metric_alarm.in_service_capacity` (legacy, unchanged address — existing state must not churn), `fleet_in_service_capacity`, `fleet_cpu`, `fleet_heap_used`, `fleet_memory`, `fleet_disk`. Output keys: `"<name>:GroupInServiceCapacity"` (both capacity variants), `"<name>:CPUUtilization"`, `"<name>:jvm.memory.heap.used"`, `"<name>:mem_used_percent"`, `"<name>:disk_used_percent"`.

- [ ] **Step 1: Split resources into legacy/fleet in `locals` and extend severities**

In `modules/cloudwatch/metrics-alarm/asg/main.tf`, replace the `locals` block with:

```hcl
locals {
  name_prefix   = "${var.project}-${var.env}-ASG"
  asg_resources = { for res in var.resources : res.name => res }

  # app_name is the fleet-mode latch: null = legacy dimension alarm only.
  legacy_resources = { for k, v in local.asg_resources : k => v if v.app_name == null }
  fleet_resources  = { for k, v in local.asg_resources : k => v if v.app_name != null }

  default_severities = {
    in_service_capacity = "ERROR"
    cpu                 = "WARN"
    heap_used           = "WARN"
    memory              = "WARN"
    disk                = "WARN"
  }
}
```

- [ ] **Step 2: Restrict the legacy alarm to legacy entries**

In the existing `resource "aws_cloudwatch_metric_alarm" "in_service_capacity"` block, change only the `for_each` source map from `local.asg_resources` to `local.legacy_resources`:

```hcl
  for_each = {
    for k, v in local.legacy_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "in_service_capacity")
  }
```

Everything else in that block stays byte-identical (state addresses for existing legacy entries are preserved).

- [ ] **Step 3: Append the five fleet alarm resources**

Append to `main.tf`:

```hcl
#------------------------------------------------------------------------------
# Fleet mode (app_name set): AppName-scoped Metrics Insights alarms.
# Membership resolves at evaluation time — ASG/instance churn needs no apply.
# A metric_query alarm cannot carry dimensions, hence separate resources.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "fleet_in_service_capacity" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "in_service_capacity")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-GroupInServiceCapacity"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.in_service_capacity)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-GroupInServiceCapacity is in ALARM state"
  )}"

  comparison_operator = "LessThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.capacity_threshold, null),
    each.value.desired_capacity
  )
  evaluation_periods  = 10
  datapoints_to_alarm = 10

  # SUM deliberately counts old+new ASGs during blue/green overlap: it can only
  # over-count, which briefly masks (never false-fires) LessThanThreshold.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 60
    expression  = "SELECT SUM(GroupInServiceCapacity) FROM SCHEMA(\"AWS/AutoScaling\", AutoScalingGroupName) WHERE tag.${var.app_tag_key} = '${each.value.app_name}'"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.in_service_capacity
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.in_service_capacity
    )]
  ] : []

  treat_missing_data = "breaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "fleet_cpu" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "cpu")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-CPUUtilization"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.cpu)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-CPUUtilization is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.cpu_threshold, null),
    var.default_cpu_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  # GROUP BY InstanceId: one series per instance; ALARM when ANY series breaches.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    expression  = "SELECT AVG(CPUUtilization) FROM SCHEMA(\"AWS/EC2\", InstanceId) WHERE tag.${var.app_tag_key} = '${each.value.app_name}' GROUP BY InstanceId"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.cpu
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.cpu
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "fleet_heap_used" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "heap_used")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-jvm.memory.heap.used"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-jvm.memory.heap.used is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  # Byte threshold from the known -Xmx: CloudWatch math cannot divide two
  # GROUP BY series arrays, so the JMX module's 100*used/max ratio is not
  # expressible here.
  threshold = floor(
    coalesce(
      try(each.value.overrides.heap_threshold_pct, null),
      var.default_heap_threshold_pct
    ) * each.value.heap_max_bytes / 100
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    expression = join("", [
      "SELECT AVG(\"jvm.memory.heap.used\") FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'",
      each.value.process_group != null ? " AND ProcessGroupName = '${each.value.process_group}'" : "",
      " GROUP BY InstanceId"
    ])
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.heap_used
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.heap_used
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "fleet_memory" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "memory")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-mem_used_percent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.memory)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-mem_used_percent is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  # Guardrail only (default 90): JVM hosts sit at 75-85% OS memory by design.
  # Heap pressure is fleet_heap_used's job.
  threshold = coalesce(
    try(each.value.overrides.memory_threshold, null),
    var.default_memory_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    expression  = "SELECT AVG(mem_used_percent) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}' GROUP BY InstanceId"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.memory
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.memory
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "fleet_disk" {
  for_each = {
    for k, v in local.fleet_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "disk")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-disk_used_percent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.disk)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-disk_used_percent is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.disk_threshold, null),
    var.default_disk_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "q1"
    return_data = true
    period      = 300
    expression  = "SELECT AVG(disk_used_percent) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}' AND path = '/' GROUP BY InstanceId"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.disk
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.disk
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "ASG"
      ResourceName = each.value.name
    }
  )
}
```

- [ ] **Step 4: Rewrite `outputs.tf` to merge legacy + fleet maps (and fix the metric-name key)**

Replace the full content of `modules/cloudwatch/metrics-alarm/asg/outputs.tf`. Note the pre-existing bug: keys said `GroupInServiceInstances` but the metric has always been `GroupInServiceCapacity` — fix it here (output-only change; flagged in the commit message for remote-state consumers):

```hcl
output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.in_service_capacity : "${k}:GroupInServiceCapacity" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_in_service_capacity : "${k}:GroupInServiceCapacity" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_cpu : "${k}:CPUUtilization" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_heap_used : "${k}:jvm.memory.heap.used" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_memory : "${k}:mem_used_percent" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_disk : "${k}:disk_used_percent" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.in_service_capacity : "${k}:GroupInServiceCapacity" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_in_service_capacity : "${k}:GroupInServiceCapacity" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_cpu : "${k}:CPUUtilization" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_heap_used : "${k}:jvm.memory.heap.used" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_memory : "${k}:mem_used_percent" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.fleet_disk : "${k}:disk_used_percent" => v.alarm_name }
  )
}
```

(The two capacity maps never collide: legacy and fleet `for_each` key sets are disjoint by construction.)

- [ ] **Step 5: Validate the module**

```bash
cd modules/cloudwatch/metrics-alarm/asg
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Plan-render a fleet fixture to inspect the generated queries**

Extend the Task 3 fixture from Task 1 (`scratchpad/asg-validation-check/main.tf`) — replace its `resources` with one legacy + one fleet entry:

```hcl
  resources = [
    {
      name             = "legacy-asg"
      desired_capacity = 2
    },
    {
      name             = "chat-fleet"
      desired_capacity = 4
      app_name         = "live"
      process_group    = "chat-server-tomcat"
      heap_max_bytes   = 12884901888
    }
  ]
```

Add a provider stub at the top of the fixture (plan needs a region; no credentials are required because fleet mode has no data sources and we plan with `-refresh=false`):

```hcl
provider "aws" {
  region                      = "ap-northeast-1"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  access_key                  = "test"
  secret_key                  = "test"
}
```

```bash
cd /tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad/asg-validation-check
podman run --rm \
  -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/asg:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm \
  -v "$PWD":/work:Z \
  -v /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm/modules/cloudwatch/metrics-alarm/asg:/work-module:Z \
  -w /work docker.io/hashicorp/terraform:1.10 plan -refresh=false
```

Expected: plan shows 6 alarms to create (1 legacy dimension alarm + 5 fleet `metric_query` alarms). Inspect the rendered expressions and confirm exactly:
- capacity: `SELECT SUM(GroupInServiceCapacity) FROM SCHEMA("AWS/AutoScaling", AutoScalingGroupName) WHERE tag.AppName = 'live'`
- heap: `SELECT AVG("jvm.memory.heap.used") FROM "CWAgent" WHERE AppName = 'live' AND ProcessGroupName = 'chat-server-tomcat' GROUP BY InstanceId`
- heap threshold: `10952166604` (floor of 85% × 12884901888)
- disk: `... WHERE AppName = 'live' AND path = '/' GROUP BY InstanceId`

If the provider rejects `metric_query` without `metric`/`expression` shape issues, that is verify-item-1 territory — stop and report rather than working around.

- [ ] **Step 7: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/asg/main.tf modules/cloudwatch/metrics-alarm/asg/outputs.tf
git commit -m "feat(asg): AppName-scoped Metrics Insights fleet alarms

Legacy entries (no app_name) keep the dimension alarm at the same state
address. Output keys fix GroupInServiceInstances -> GroupInServiceCapacity
(metric-name bug); remote-state consumers see renamed keys.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: EC2 module `disk` alarm

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/ec2/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/ec2/main.tf`
- Modify: `modules/cloudwatch/metrics-alarm/ec2/outputs.tf`

**Interfaces:**
- Produces: `overrides.disk_threshold`, `var.default_disk_threshold` (85), alarm resource `aws_cloudwatch_metric_alarm.disk`, output key `"<name>:disk_used_percent"`, `disk` in the `disabled_alarms` valid set.

- [ ] **Step 1: Extend `variables.tf`**

In the `resources` type, add `disk_threshold = optional(number)` after `memory_threshold`:

```hcl
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
      disk_threshold   = optional(number)
      disabled_alarms  = optional(set(string), [])
    }), {})
```

Add a range validation after the existing `memory_threshold` validation block:

```hcl
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.disk_threshold, null) == null
      || (coalesce(try(r.overrides.disk_threshold, null), 0) >= 0 && coalesce(try(r.overrides.disk_threshold, null), 0) <= 100)
    ])
    error_message = "overrides.disk_threshold must be between 0 and 100 inclusive, or omitted."
  }
```

Update the `disabled_alarms` validation's allowed list and message:

```hcl
        contains(["status_check", "status_check_ebs", "cpu", "memory", "disk"], m)
```
```hcl
    error_message = "overrides.disabled_alarms entries must be a subset of: status_check, status_check_ebs, cpu, memory, disk"
```

Append after `default_memory_threshold`:

```hcl
variable "default_disk_threshold" {
  description = "Default threshold for disk_used_percent (path /). Requires the CWAgent disk plugin with an [InstanceId, path] rollup — see cwagent/ec2-java/."
  type        = number
  default     = 85
}
```

- [ ] **Step 2: Add the alarm to `main.tf` and the severity default**

Add `disk = "WARN"` to `local.default_severities` (after `memory = "WARN"`). Append at the end of `main.tf`:

```hcl
#------------------------------------------------------------------------------
# disk_used_percent Alarm (CloudWatch Agent metric)
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "disk" {
  for_each = {
    for k, v in local.ec2_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "disk")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-disk_used_percent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.disk)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-disk_used_percent is in ALARM state"
  )}"

  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.disk_threshold, null),
    var.default_disk_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  period              = 300

  # Feeds on the cwagent/ec2-java [InstanceId, path] rollup: a classic alarm's
  # dimensions must match the series exactly (raw disk series also carry fstype).
  dimensions = {
    InstanceId = data.aws_instance.this[each.key].id
    path       = "/"
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.disk
    )]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(
      try(each.value.overrides.severity, null),
      local.default_severities.disk
    )]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "EC2"
      ResourceName = each.value.name
    }
  )
}
```

- [ ] **Step 3: Extend `outputs.tf`**

Add one line to each merge (after the `memory` line):

```hcl
    { for k, v in aws_cloudwatch_metric_alarm.disk : "${k}:disk_used_percent" => v.arn }
```
```hcl
    { for k, v in aws_cloudwatch_metric_alarm.disk : "${k}:disk_used_percent" => v.alarm_name }
```

(Remember the comma on the previous line of each merge.)

- [ ] **Step 4: Validate**

```bash
cd modules/cloudwatch/metrics-alarm/ec2
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/ec2/
git commit -m "feat(ec2): disk_used_percent alarm on {InstanceId, path=/}

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: CWAgent template `cwagent/ec2-java/`

**Files:**
- Create: `cwagent/ec2-java/amazon-cloudwatch-agent-java.json`
- Create: `cwagent/ec2-java/README.md`

**Interfaces:**
- Produces: the metric contract consumed by Task 2's queries (`AppName` dimension on every plugin, `jvm.*` names, 60s interval) and Task 3's rollup (`[InstanceId, path]`). Placeholders: `<app-name>`, `<process-group>`, `<jmx-endpoint>`, `<app-log-path>`, `<log-group>`.

- [ ] **Step 1: Write the template JSON**

Create `cwagent/ec2-java/amazon-cloudwatch-agent-java.json` with exactly the template from the spec section "CWAgent config template" (`docs/superpowers/specs/2026-07-24-asg-fleet-alarms-design.md`). Copy it verbatim — it is the reviewed artifact; do not re-derive it.

- [ ] **Step 2: Verify it is valid JSON once placeholders are substituted**

```bash
sed -e 's/<app-name>/live/g' -e 's/<process-group>/chat-server-tomcat/g' \
    -e 's|<jmx-endpoint e.g. localhost:9999>|localhost:9999|g' \
    -e 's|<app-log-path>|/apps/x/logs/app.log|g' -e 's|<log-group>|/live/apps/x/logs/|g' \
    cwagent/ec2-java/amazon-cloudwatch-agent-java.json | python3 -m json.tool > /dev/null && echo VALID
```

Expected: `VALID`

- [ ] **Step 3: Write the README contract**

Create `cwagent/ec2-java/README.md`:

```markdown
# CWAgent config template — Java EC2 hosts (standalone + ASG fleets)

Reference template for the CloudWatch Agent config used by Java hosts. The
**live copy lives in SSM Parameter Store** (one parameter per fleet / host
group) with the placeholders below substituted; hosts fetch it with
`amazon-cloudwatch-agent-ctl -a fetch-config -c ssm:<parameter-name>`.
This repo manages alarms, not compute — keep this file in sync with the
Parameter Store copies when the contract changes.

## Placeholders (the entire per-fleet substitution surface)

| Placeholder | Meaning | Example |
|---|---|---|
| `<app-name>` | Fleet identity. MUST equal the `app_name` in tfvars and the `AppName` tag on the EC2 instances/ASG. One AppName = one fleet. | `live` |
| `<process-group>` | Java process label within the fleet (JMX dimension `ProcessGroupName`). | `chat-server-tomcat` |
| `<jmx-endpoint e.g. localhost:9999>` | JMX RMI endpoint the JVM exposes. The Java process must be started with JMX remote enabled on this port. | `localhost:9999` |
| `<app-log-path>` / `<log-group>` | App log shipping (out of alarm scope). | — |

## Contract (floor, not ceiling)

Consumed by `modules/cloudwatch/metrics-alarm/asg` (fleet mode),
`modules/cloudwatch/metrics-alarm/ec2` (memory/disk), and
`modules/cloudwatch/metrics-alarm/jmx` (standalone JVM alarms):

- Namespace `CWAgent`; 60s collection interval.
- Dimension `AppName` (static, plugin-level) on **every** metrics plugin —
  fleet Insights queries filter `WHERE AppName = '<v>'`.
- Dimension `ProcessGroupName` on `jmx`; `InstanceId` via global
  `append_dimensions`.
- OTel `jvm.*` metric names as listed in the template.
- `aggregation_dimensions [["InstanceId"], ["InstanceId", "path"]]`:
  the `[InstanceId]` rollup feeds the EC2 `memory` alarm and the JMX module's
  heap/GC alarms; `[InstanceId, path]` feeds the EC2 `disk` alarm. Fleet
  Insights queries read the full-dimension series and ignore rollups.
- Never append `${aws:AutoScalingGroupName}` as an identity key — it churns
  on every CodeDeploy blue/green deployment (the exact problem the fleet
  alarms exist to avoid).
- Extra plugins/metrics are allowed (swap, ethtool, netstat, … are collected
  but not alarmed yet; see the spec's future-candidates list).

## Rollout order per host group

1. Parameter Store config created/updated from this template
2. Java process exposes the JMX endpoint
3. Agent restarted; metrics flowing (verify with the preflight script)
4. Alarms applied (`asg_resources` fleet entry / `ec2_resources` entry)

Related: `cwagent/jmx/` is the older standalone-JMX-only contract; hosts
adopting this template satisfy it too.
```

- [ ] **Step 4: Commit**

```bash
git add cwagent/ec2-java/
git commit -m "feat(cwagent): ec2-java config template + contract README

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Preflight script + workflow wiring

**Files:**
- Create: `scripts/check_asg_fleet_metrics.sh` (mode 0755)
- Modify: `.github/workflows/preflight.yml`

**Interfaces:**
- Consumes: `asg_resources` tfvars entries (fields `name`, `app_name`, `heap_max_bytes`, `overrides.disabled_alarms`) and `aws_region`.
- Produces: exit 0 when all fleet prerequisites hold (or no fleet entries), exit 1 otherwise. Uses `cloudwatch:GetMetricData` — confirm `PREFLIGHT_READ_ROLE_ARN` allows it (note in commit message).

- [ ] **Step 1: Write the script**

Create `scripts/check_asg_fleet_metrics.sh`. Design note: unlike the older list-metrics checks, this one runs **the same Metrics Insights SELECTs the alarms use** via `get-metric-data` — so it also proves tag telemetry (`AWS/AutoScaling` query) and the query path end-to-end.

```bash
#!/usr/bin/env bash
# Checks fleet-mode asg_resources (entries with app_name) prerequisites by
# running the SAME Metrics Insights queries the fleet alarms use:
#   - running EC2 instances tagged AppName=<v> exist
#   - tag-scoped GroupInServiceCapacity query returns data (proves the
#     CloudWatch "resource tags on telemetry" setting + ASG tag)
#   - CWAgent series with AppName=<v>: mem_used_percent, disk_used_percent,
#     and (unless heap_used disabled) jvm.memory.heap.used
#   - latest jvm.memory.heap.max ~= heap_max_bytes (+/-10%) — catches a
#     tfvars/-Xmx mismatch before it skews the heap alarm's byte threshold
# All fleet alarms except capacity treat missing data as notBreaching: a
# mis-dimensioned fleet would sit green forever. Exits 1 on any failure.
#
# Assumes the tag key is AppName (the module's app_tag_key default).
#
# Usage: check_asg_fleet_metrics.sh --tfvars <path>

set -euo pipefail

TFVARS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TFVARS" ]]; then
  echo "Usage: $0 --tfvars <path>" >&2
  exit 1
fi

[[ -f "$TFVARS" ]] || { echo "Error: $TFVARS not found." >&2; exit 1; }

REGION=$(python3 - "$TFVARS" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
m = re.search(r'aws_region\s*=\s*"([^"]+)"', content)
print(m.group(1) if m else "")
EOF
)

# Emits one line per fleet entry: name<TAB>app_name<TAB>heap_max_bytes<TAB>check_heap
# heap_max_bytes prints "-" when unset; check_heap is 1 unless heap_used is in
# disabled_alarms. Same brace-depth parser as check_jmx_metrics.sh.
extract_fleet_entries() {
python3 - "$TFVARS" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()

start = re.search(r'asg_resources\s*=\s*\[', content)
if not start:
    sys.exit(0)

i, depth, body = start.end(), 1, []
while i < len(content) and depth > 0:
    c = content[i]
    if c == '[':
        depth += 1
    elif c == ']':
        depth -= 1
        if depth == 0:
            break
    body.append(c)
    i += 1
body = ''.join(body)

entries, depth, cur = [], 0, []
for c in body:
    if c == '{':
        depth += 1
        if depth == 1:
            cur = []
            continue
    if c == '}':
        depth -= 1
        if depth == 0:
            entries.append(''.join(cur))
            continue
    if depth >= 1:
        cur.append(c)

for e in entries:
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    ap = re.search(r'\bapp_name\s*=\s*"([^"]+)"', e)
    if not nm or not ap:
        continue  # legacy entry or malformed
    hm = re.search(r'\bheap_max_bytes\s*=\s*(\d+)', e)
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    check_heap = 0 if "heap_used" in disabled else 1
    print(f"{nm.group(1)}\t{ap.group(1)}\t{hm.group(1) if hm else '-'}\t{check_heap}")
EOF
}

ENTRIES=$(extract_fleet_entries)

if [[ -z "$ENTRIES" ]]; then
  echo "No fleet-mode asg_resources (app_name) found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0
START=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Runs one Metrics Insights SELECT via get-metric-data; prints the latest
# value, or nothing when the query returned no datapoints.
insights_latest() {
  local EXPRESSION="$1"
  aws cloudwatch get-metric-data \
    --region "$REGION" \
    --start-time "$START" \
    --end-time "$END" \
    --metric-data-queries "[{\"Id\":\"q1\",\"Expression\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$EXPRESSION"),\"Period\":300}]" \
    --query "MetricDataResults[0].Values[0]" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

check_query() {
  local NAME="$1" LABEL="$2" EXPRESSION="$3" HINT="$4"
  local VALUE
  VALUE=$(insights_latest "$EXPRESSION")
  if [[ -z "$VALUE" ]]; then
    echo "WARNING: [$NAME] $LABEL query returned no data. $HINT" >&2
    FAILED=1
  else
    echo "OK: [$NAME] $LABEL (latest: $VALUE)"
  fi
}

while IFS=$'\t' read -r NAME APP HEAP_MAX CHECK_HEAP; do
  echo "--- Fleet entry '$NAME' (AppName=$APP)"

  COUNT=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:AppName,Values=$APP" "Name=instance-state-name,Values=running" \
    --query "length(Reservations[].Instances[])" \
    --output text 2>/dev/null || echo "0")
  if [[ "$COUNT" == "0" || -z "$COUNT" ]]; then
    echo "WARNING: [$NAME] no running instances tagged AppName=$APP in $REGION. Check the launch template tag propagation." >&2
    FAILED=1
  else
    echo "OK: [$NAME] $COUNT running instance(s) tagged AppName=$APP."
  fi

  check_query "$NAME" "GroupInServiceCapacity (tag telemetry)" \
    "SELECT SUM(GroupInServiceCapacity) FROM SCHEMA(\"AWS/AutoScaling\", AutoScalingGroupName) WHERE tag.AppName = '$APP'" \
    "Enable CloudWatch 'resource tags on telemetry' and tag the ASG itself with AppName=$APP."

  check_query "$NAME" "mem_used_percent" \
    "SELECT AVG(mem_used_percent) FROM \"CWAgent\" WHERE AppName = '$APP' GROUP BY InstanceId" \
    "Deploy the cwagent/ec2-java/ config (AppName dimension on the mem plugin)."

  check_query "$NAME" "disk_used_percent" \
    "SELECT AVG(disk_used_percent) FROM \"CWAgent\" WHERE AppName = '$APP' AND path = '/' GROUP BY InstanceId" \
    "Deploy the cwagent/ec2-java/ config (AppName dimension on the disk plugin, resources ['/'])."

  if [[ "$CHECK_HEAP" == "1" ]]; then
    check_query "$NAME" "jvm.memory.heap.used" \
      "SELECT AVG(\"jvm.memory.heap.used\") FROM \"CWAgent\" WHERE AppName = '$APP' GROUP BY InstanceId" \
      "Deploy the cwagent/ec2-java/ config and expose the JMX endpoint on the JVM."

    if [[ "$HEAP_MAX" != "-" ]]; then
      ACTUAL_MAX=$(insights_latest "SELECT MAX(\"jvm.memory.heap.max\") FROM \"CWAgent\" WHERE AppName = '$APP'")
      if [[ -z "$ACTUAL_MAX" ]]; then
        echo "WARNING: [$NAME] jvm.memory.heap.max query returned no data; cannot sanity-check heap_max_bytes=$HEAP_MAX." >&2
        FAILED=1
      else
        WITHIN=$(python3 -c "import sys; a=float(sys.argv[1]); e=float(sys.argv[2]); print(1 if abs(a-e)/e <= 0.10 else 0)" "$ACTUAL_MAX" "$HEAP_MAX")
        if [[ "$WITHIN" == "1" ]]; then
          echo "OK: [$NAME] heap_max_bytes=$HEAP_MAX matches observed jvm.memory.heap.max=$ACTUAL_MAX (±10%)."
        else
          echo "WARNING: [$NAME] heap_max_bytes=$HEAP_MAX but observed jvm.memory.heap.max=$ACTUAL_MAX (>10% off). Fix tfvars or -Xmx; the heap alarm threshold derives from this." >&2
          FAILED=1
        fi
      fi
    fi
  fi
done <<< "$ENTRIES"

exit "$FAILED"
```

Then: `chmod +x scripts/check_asg_fleet_metrics.sh`

- [ ] **Step 2: Test the skip path and the parser locally (no AWS needed)**

```bash
bash -n scripts/check_asg_fleet_metrics.sh && echo SYNTAX-OK

SCRATCH=/tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad
cat > "$SCRATCH/no-fleet.tfvars" <<'EOF'
aws_region = "ap-northeast-1"
asg_resources = [
  { name = "legacy-asg", desired_capacity = 2 },
]
EOF
scripts/check_asg_fleet_metrics.sh --tfvars "$SCRATCH/no-fleet.tfvars"
echo "exit=$?"
```

Expected: `No fleet-mode asg_resources (app_name) found ... — skipping.` and `exit=0`.

```bash
cat > "$SCRATCH/fleet.tfvars" <<'EOF'
aws_region = "ap-northeast-1"
asg_resources = [
  { name = "legacy-asg", desired_capacity = 2 },
  {
    name             = "chat-fleet"
    desired_capacity = 4
    app_name         = "live"
    heap_max_bytes   = 12884901888
    overrides = { disabled_alarms = ["disk"] }
  },
]
EOF
# Exercise the parser by running the script with a fake `aws` that always
# fails fast — parser output is observable, AWS checks all warn:
PATH="$SCRATCH/fakebin:$PATH"
mkdir -p "$SCRATCH/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/fakebin/aws" && chmod +x "$SCRATCH/fakebin/aws"
scripts/check_asg_fleet_metrics.sh --tfvars "$SCRATCH/fleet.tfvars" || echo "exit=$? (expected 1: all AWS checks warned)"
```

Expected: the header line `--- Fleet entry 'chat-fleet' (AppName=live)` appears (parser found exactly the fleet entry, skipped the legacy one), every check prints a WARNING (fake aws), and exit is 1. The real AWS run happens on the work machine.

- [ ] **Step 3: Add the workflow step**

Append to `.github/workflows/preflight.yml` after the "Run JMX metric check" step (same indentation):

```yaml
      - name: Run ASG fleet metric check
        if: steps.changed.outputs.tfvars == 'true'
        run: |
          FAILED=0
          for tfvars in ${{ steps.changed.outputs.tfvars_files }}; do
            echo "--- Checking ASG fleet metrics: $tfvars"
            scripts/check_asg_fleet_metrics.sh --tfvars "$tfvars" || FAILED=1
          done
          exit $FAILED
```

- [ ] **Step 4: Commit**

```bash
git add scripts/check_asg_fleet_metrics.sh .github/workflows/preflight.yml
git commit -m "feat(preflight): fleet metric check via real Metrics Insights queries

Runs the same SELECTs the fleet alarms use (get-metric-data), so it also
proves tag telemetry end-to-end. PREFLIGHT_READ_ROLE_ARN must allow
cloudwatch:GetMetricData.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Stack wiring (`stacks/projects/billing/dev/variables.tf`)

**Files:**
- Modify: `stacks/projects/billing/dev/variables.tf` (the `asg_resources` and `ec2_resources` variable types)

**Interfaces:**
- Consumes: module interfaces from Tasks 1 and 3. Stack `main.tf` and `outputs.tf` need no changes (module call passes `resources` through; outputs already `try(...)`-wrapped).

- [ ] **Step 1: Mirror the new fields in the stack variable types**

In `stacks/projects/billing/dev/variables.tf`, replace the `asg_resources` type with:

```hcl
variable "asg_resources" {
  description = "ASG resources to monitor. Set app_name for fleet mode (AppName-scoped Metrics Insights alarms; see docs/superpowers/specs/2026-07-24-asg-fleet-alarms-design.md)."
  type = list(object({
    name             = string
    desired_capacity = number
    app_name         = optional(string)
    heap_max_bytes   = optional(number)
    process_group    = optional(string)
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
      cpu_threshold      = optional(number)
      memory_threshold   = optional(number)
      heap_threshold_pct = optional(number)
      disk_threshold     = optional(number)
      disabled_alarms    = optional(set(string), [])
    }), {})
  }))
  default = []
}
```

And add `disk_threshold = optional(number)` to `ec2_resources`'s overrides (after `memory_threshold`):

```hcl
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
      disk_threshold   = optional(number)
      disabled_alarms  = optional(set(string), [])
    }), {})
```

- [ ] **Step 2: Validate the stack**

```bash
cd stacks/projects/billing/dev
podman run --rm -v "$PWD/../../../..":/repo:Z -w /repo/stacks/projects/billing/dev docker.io/hashicorp/terraform:1.10 init -backend=false
podman run --rm -v "$PWD/../../../..":/repo:Z -w /repo/stacks/projects/billing/dev docker.io/hashicorp/terraform:1.10 validate
```

(Mount the repo root — the stack references `../../../../modules/...`.)
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add stacks/projects/billing/dev/variables.tf
git commit -m "feat(stacks): expose ASG fleet-mode and EC2 disk fields in billing/dev

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Documentation (CLAUDE.md) + final sweep

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

Three edits:

1. In "Special Module Behaviors", replace the ASG bullet with:

```markdown
- **ASG**: Requires `desired_capacity` per resource. Two modes per entry: legacy (no `app_name`) keeps the classic `AutoScalingGroupName`-dimension GroupInServiceCapacity alarm; fleet mode (`app_name` set) targets CodeDeploy-churned ASGs whose instance IDs and ASG-name suffix change every deploy — five `AppName`-scoped Metrics Insights alarms (capacity `SUM` watchdog missing-data=breaching; per-instance CPU/heap/memory-guardrail/disk via `GROUP BY InstanceId`, missing-data=notBreaching) that re-resolve membership at every evaluation, so churn needs no re-apply. `heap_max_bytes` (JVM `-Xmx`) is required in fleet mode unless `heap_used` is disabled — the heap alarm is a byte threshold (`heap_threshold_pct` × `heap_max_bytes`) because CloudWatch math can't divide two GROUP BY series arrays. OS memory defaults to 90 (guardrail: JVM hosts sit at 75–85% by design; heap_used is the real memory signal). Identity contract: tfvars `app_name` = `AppName` tag on instances+ASG = CWAgent `AppName` dimension (see `cwagent/ec2-java/`); requires the CloudWatch "resource tags on telemetry" account setting for the native-metric queries.
```

2. In the same section's EC2 bullet, append:

```markdown
 A `disk` alarm (`disk_used_percent`, `{InstanceId, path="/"}`) requires the agent's `[InstanceId, path]` rollup from `cwagent/ec2-java/`.
```

3. In "Preflight Checks", add `scripts/check_asg_fleet_metrics.sh` to the script list and append after the existing parenthetical about the JMX check:

```markdown
The ASG fleet check runs the alarms' actual Metrics Insights SELECTs via `get-metric-data` (so it proves tag telemetry + `AppName` series end-to-end) and sanity-checks `heap_max_bytes` against observed `jvm.memory.heap.max` (±10%); it needs `cloudwatch:GetMetricData` on the preflight role.
```

Also mention `cwagent/ec2-java/` in the Dashboards/cwagent sentence: after the sentence about `cwagent/jmx/`, add:

```markdown
`cwagent/ec2-java/` is the full Java-host template (JMX + system metrics, `AppName` fleet dimension); its live copies live in SSM Parameter Store.
```

- [ ] **Step 2: Repo-wide fmt check + full module validate sweep**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 fmt -recursive -check
```

Expected: no output (nothing left unformatted). If files are listed, run without `-check` and stage them.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: ASG fleet mode, EC2 disk alarm, ec2-java cwagent template

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Clean up scratch fixtures**

```bash
rm -rf /tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad/asg-validation-check \
       /tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad/no-fleet.tfvars \
       /tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad/fleet.tfvars \
       /tmp/claude-1000/-home-eric-Documents-Code-terraform-resource-type-based-metric-alarm/77fd05fc-b550-4379-a2d2-0cfdb86124a3/scratchpad/fakebin
```

---

## Out of scope (work machine; from the spec — do NOT attempt here)

- Parameter Store upload; JMX port exposure; `AppName` tags on launch template + ASG; the CloudWatch "resource tags on telemetry" account setting.
- Blocking verify items before any real apply: hand-create one multi-series `GROUP BY` alarm via Terraform (provider support unconfirmed); confirm tag telemetry covers `AWS/AutoScaling`; confirm rollup/dimension changes land via `list-metrics`; churn test (replace an instance, alarm tracks successor with no apply).
- Deferred: fleet GC-time alarm (multi-series `DIFF()` unverified).
