# EFS + JVM/JMX Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an EFS throughput-utilization trend alarm module and a JVM/JMX monitoring stack (cwagent config artifact + JMX alarm module + CloudWatch dashboard) to the resource-type-based metric-alarm repo.

**Architecture:** Two new library modules under `modules/cloudwatch/metrics-alarm/` (`efs`, `jmx`) follow the existing module pattern (per-metric severity map, `coalesce()` threshold chains, `disabled_alarms` opt-out, severity→SNS routing). EFS introduces the repo's first **metric-math** alarm (`MeteredIOBytes`÷`PermittedThroughput`). JMX reuses the EC2 Name-tag→InstanceId lookup and alarms on CloudWatch-Agent-emitted OTel JVM metrics. A dashboard module builds its body with `jsonencode()` (single source) and emits it as an output for the importable static artifact. The cwagent JMX config ships as an artifact under `cwagent/jmx/`, outside the alarm modules.

**Tech Stack:** Terraform ≥ 1.10, hashicorp/aws ≥ 5.0, AWS CloudWatch (metric alarms, metric math, dashboards), amazon-cloudwatch-agent JMX/JVM receiver. Terraform runs containerized.

## Global Constraints

- Terraform `required_version >= 1.10`; provider `hashicorp/aws` `>= 5.0`. Library modules declare `terraform { required_providers { aws = { source = "hashicorp/aws", version = ">= 5.0" } } }` inside `main.tf` (matches the cloudfront module; no separate `versions.tf`).
- Every module variable has a `validation {}` block. `severity` ∈ {`WARN`,`ERROR`,`CRIT`} (case-sensitive) or omitted. `sns_topic_arns` is `object({WARN,ERROR,CRIT})` of `arn:aws:sns:` strings.
- Alarm name: `{Project}-{Env}-{ResourceType}-[{ResourceName}]-{MetricName}`; built once as `local.name_prefix = "${var.project}-${var.env}-{ResourceType}"`. Description: `[{SEVERITY}]-{text}`.
- `disabled_alarms` is opt-out (default `[]` = all on); valid ids = active alarm resource labels, enforced by a `validation {}` block.
- `outputs.tf` exports `alarm_arns` and `alarm_names` maps keyed `"<resource-key>:<metric-id>"`.
- Tags: `merge(var.common_tags, { Project, ResourceType, ResourceName })` (module tags win on collision).
- Terraform is **containerized** (terraform is not on host). Run module validation with:
  ```bash
  podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
    sh -c "terraform init -backend=false && terraform validate"
  ```
  Run this from inside the module directory (so `$PWD` is the module). `:Z` is required on Fedora. `terraform fmt -recursive` from repo root before final commit.
- Defaults: EFS throughput-util 80% / 6h-sustained (3600s×6), WARN. JMX heap 85% WARN, GC time 6000 ms/min WARN. All overridable per-resource.

---

## Task 1: EFS library module

**Files:**
- Create: `modules/cloudwatch/metrics-alarm/efs/variables.tf`
- Create: `modules/cloudwatch/metrics-alarm/efs/outputs.tf`
- Create: `modules/cloudwatch/metrics-alarm/efs/main.tf`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces: module at `modules/cloudwatch/metrics-alarm/efs` with inputs `project` (string), `env` (string), `resources` (list of `{file_system_id, name?, enabled?, overrides?}`), `sns_topic_arns` (object WARN/ERROR/CRIT), `default_throughput_util_threshold` (number, default 80), `common_tags` (map). Outputs `alarm_arns`, `alarm_names` keyed `"<file_system_id>:throughput_util"`.

- [ ] **Step 1: Write `variables.tf` and `outputs.tf` (outputs reference the not-yet-created alarm resource — this is the failing state)**

`modules/cloudwatch/metrics-alarm/efs/variables.tf`:
```hcl
variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of EFS file systems to monitor"
  type = list(object({
    file_system_id = string
    name           = optional(string)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity                  = optional(string)
      description               = optional(string)
      throughput_util_threshold = optional(number)
      period                    = optional(number)
      evaluation_periods        = optional(number)
      disabled_alarms           = optional(set(string), [])
    }), {})
  }))
  validation {
    condition     = alltrue([for r in var.resources : can(regex("^fs-", r.file_system_id))])
    error_message = "file_system_id must be an EFS file system id starting with 'fs-'."
  }
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
      try(r.overrides.throughput_util_threshold, null) == null
      || (coalesce(try(r.overrides.throughput_util_threshold, null), 0) >= 0 && coalesce(try(r.overrides.throughput_util_threshold, null), 0) <= 100)
    ])
    error_message = "overrides.throughput_util_threshold must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) : contains(["throughput_util"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: throughput_util"
  }
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs mapped by severity"
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  validation {
    condition     = alltrue([for k in ["WARN", "ERROR", "CRIT"] : can(regex("^arn:aws:sns:", var.sns_topic_arns[k]))])
    error_message = "sns_topic_arns values must be SNS ARNs (starting with arn:aws:sns:)."
  }
}

variable "default_throughput_util_threshold" {
  description = "Default threshold (percent) for EFS throughput utilization"
  type        = number
  default     = 80
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
```

`modules/cloudwatch/metrics-alarm/efs/outputs.tf`:
```hcl
output "alarm_arns" {
  description = "Map of <resource-key>:<metric-id> to alarm ARN for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.throughput_util : "${k}:throughput_util" => v.arn }
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-id> to alarm name for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.throughput_util : "${k}:throughput_util" => v.alarm_name }
}
```

- [ ] **Step 2: Run validate to verify it fails**

```bash
cd modules/cloudwatch/metrics-alarm/efs
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false && terraform validate"
```
Expected: FAIL — `Reference to undeclared resource ... aws_cloudwatch_metric_alarm.throughput_util` (outputs reference a resource not yet defined).

- [ ] **Step 3: Write `main.tf`**

`modules/cloudwatch/metrics-alarm/efs/main.tf`:
```hcl
#------------------------------------------------------------------------------
# EFS Monitoring Module
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
  name_prefix   = "${var.project}-${var.env}-EFS"
  efs_resources = { for res in var.resources : res.file_system_id => res }

  default_severities = {
    throughput_util = "WARN"
  }
}

#------------------------------------------------------------------------------
# Throughput Utilization (%) — metric-math alarm.
# Not a published metric: utilization = metered throughput / permitted throughput.
#   metered MiBps  = Sum(MeteredIOBytes) / PERIOD
#   permitted Bps  = Average(PermittedThroughput)
# Watched over a long span (default 3600s x 6 = 6h sustained) to track the trend
# rather than fire on short spikes.
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "throughput_util" {
  for_each = {
    for k, v in local.efs_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "throughput_util")
  }

  alarm_name = "${local.name_prefix}-[${coalesce(each.value.name, each.value.file_system_id)}]-ThroughputUtilization"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.throughput_util)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${coalesce(each.value.name, each.value.file_system_id)}]-ThroughputUtilization is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.throughput_util_threshold, null),
    var.default_throughput_util_threshold
  )
  evaluation_periods  = coalesce(try(each.value.overrides.evaluation_periods, null), 6)
  datapoints_to_alarm = coalesce(try(each.value.overrides.evaluation_periods, null), 6)

  metric_query {
    id          = "e1"
    expression  = "100*(m1/PERIOD(m1))/m2"
    label       = "ThroughputUtilization"
    return_data = true
  }

  metric_query {
    id = "m1"
    metric {
      namespace   = "AWS/EFS"
      metric_name = "MeteredIOBytes"
      stat        = "Sum"
      period      = coalesce(try(each.value.overrides.period, null), 3600)
      dimensions  = { FileSystemId = each.value.file_system_id }
    }
  }

  metric_query {
    id = "m2"
    metric {
      namespace   = "AWS/EFS"
      metric_name = "PermittedThroughput"
      stat        = "Average"
      period      = coalesce(try(each.value.overrides.period, null), 3600)
      dimensions  = { FileSystemId = each.value.file_system_id }
    }
  }

  alarm_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.throughput_util)]
  ] : []

  ok_actions = each.value.enabled ? [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.throughput_util)]
  ] : []

  treat_missing_data = "notBreaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "EFS"
      ResourceName = coalesce(each.value.name, each.value.file_system_id)
    }
  )
}
```

- [ ] **Step 4: Run validate to verify it passes**

```bash
cd modules/cloudwatch/metrics-alarm/efs
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false && terraform validate"
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git add modules/cloudwatch/metrics-alarm/efs
git commit -m "feat(metrics): add EFS throughput-utilization trend alarm module"
```

---

## Task 2: Wire EFS into the project stack + config examples

**Files:**
- Modify: `stacks/projects/billing/dev/variables.tf` (add `efs_resources`)
- Modify: `stacks/projects/billing/dev/main.tf` (add `module "efs_alarms"`)
- Modify: `stacks/projects/billing/dev/config.yaml.example` (add `efs:` block)
- Modify: `stacks/projects/billing/dev/terraform.tfvars.example` (add `efs_resources`)

**Interfaces:**
- Consumes: the `efs` module from Task 1 (`project`, `env`, `resources`, `sns_topic_arns`, `common_tags`).
- Produces: `var.efs_resources` and `module.efs_alarms` in the billing/dev stack.

- [ ] **Step 1: Add the `efs_resources` variable**

Append to `stacks/projects/billing/dev/variables.tf`:
```hcl
variable "efs_resources" {
  description = "EFS file systems to monitor."
  type = list(object({
    file_system_id = string
    name           = optional(string)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity                  = optional(string)
      description               = optional(string)
      throughput_util_threshold = optional(number)
      period                    = optional(number)
      evaluation_periods        = optional(number)
      disabled_alarms           = optional(set(string), [])
    }), {})
  }))
  default = []
}
```

- [ ] **Step 2: Add the module block**

Append to `stacks/projects/billing/dev/main.tf`:
```hcl
module "efs_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/efs"
  count  = length(var.efs_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.efs_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}
```

- [ ] **Step 3: Add the `efs:` example block to `config.yaml.example`**

Insert under the `resources:` map in `stacks/projects/billing/dev/config.yaml.example` (after an existing block, matching the file's indentation):
```yaml
  # EFS throughput-utilization trend (metric-math alarm, default 6h-sustained >=80%).
  # Identify by file_system_id (fs-xxxx); optional name is for alarm naming only.
  efs:
    - file_system_id: fs-0123456789abcdef0
      name: billing-shared-efs
    # widen the window and tighten the threshold for a busier file system
    - file_system_id: fs-0fedcba9876543210
      name: billing-reports-efs
      overrides:
        throughput_util_threshold: 70
        period:             3600
        evaluation_periods: 12      # 12h sustained
        severity:           ERROR
```

- [ ] **Step 4: Add `efs_resources` to `terraform.tfvars.example`**

Append to `stacks/projects/billing/dev/terraform.tfvars.example`:
```hcl
efs_resources = [
  { file_system_id = "fs-0123456789abcdef0", name = "billing-shared-efs" },
  {
    file_system_id = "fs-0fedcba9876543210"
    name           = "billing-reports-efs"
    overrides      = { throughput_util_threshold = 70, evaluation_periods = 12, severity = "ERROR" }
  },
]
```

- [ ] **Step 5: Validate the stack parses (no backend/creds — expect provider/remote-state init to be the only blocker)**

```bash
cd stacks/projects/billing/dev
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform fmt -check && terraform init -backend=false 2>&1 | tail -5"
```
Expected: `terraform fmt -check` passes (no output, exit 0). `init -backend=false` may still resolve modules; the new `../../../../modules/cloudwatch/metrics-alarm/efs` source must resolve without "module not found". (Full `validate` here needs remote-state data sources and is exercised on the work machine; do not block on it.)

- [ ] **Step 6: Commit**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git add stacks/projects/billing/dev
git commit -m "feat(metrics): wire EFS alarms into billing/dev stack + examples"
```

---

## Task 3: CloudWatch Agent JMX config artifact

**Files:**
- Create: `cwagent/jmx/amazon-cloudwatch-agent-jmx.json`
- Create: `cwagent/jmx/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the **metric/dimension contract** the JMX alarm module (Task 4) and dashboard (Task 6) depend on — namespace `CWAgent`, dimension `InstanceId`, metric names `jvm.memory.heap.used`, `jvm.memory.heap.committed`, `jvm.memory.heap.max`, `jvm.gc.collections.count`, `jvm.gc.collections.elapsed`, `jvm.threads.count`, `jvm.classes.loaded`.

- [ ] **Step 1: Write the agent config**

`cwagent/jmx/amazon-cloudwatch-agent-jmx.json`:
```json
{
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "aggregation_dimensions": [
      ["InstanceId"]
    ],
    "metrics_collected": {
      "jmx": [
        {
          "endpoint": "localhost:9999",
          "jvm": {
            "measurement": [
              "jvm.memory.heap.used",
              "jvm.memory.heap.committed",
              "jvm.memory.heap.max",
              "jvm.gc.collections.count",
              "jvm.gc.collections.elapsed",
              "jvm.threads.count",
              "jvm.classes.loaded"
            ]
          }
        }
      ]
    }
  }
}
```

- [ ] **Step 2: Verify it is valid JSON**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
python3 -m json.tool cwagent/jmx/amazon-cloudwatch-agent-jmx.json > /dev/null && echo "valid json"
```
Expected: `valid json`.

- [ ] **Step 3: Write the README**

`cwagent/jmx/README.md`:
```markdown
# CloudWatch Agent — JMX / JVM metrics

Collects JVM metrics from a Java app exposing JMX on `localhost:9999` and publishes
them to CloudWatch. The alarm module (`modules/cloudwatch/metrics-alarm/jmx`) and the
JVM dashboard depend on the contract below.

## Contract (do not change without updating alarms + dashboard)

- **Namespace:** `CWAgent`
- **Dimension:** `InstanceId` (added via `append_dimensions`)
- **Metrics:** `jvm.memory.heap.used`, `jvm.memory.heap.committed`, `jvm.memory.heap.max`,
  `jvm.gc.collections.count`, `jvm.gc.collections.elapsed`, `jvm.threads.count`,
  `jvm.classes.loaded`

## Prerequisites

- `amazon-cloudwatch-agent` with JMX support installed on the host.
- The JVM exposes JMX on `localhost:9999`. For a local-only, unauthenticated endpoint,
  start the app with:
  `-Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=9999`
  `-Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false`
  `-Djava.rmi.server.hostname=localhost`
  (If JMX requires auth/SSL, add the corresponding `username`/`password`/`keystore`
  fields to the `jmx` block per the agent docs.)

## Deploy — option A: merge into an existing agent config (manual)

If the host already runs the agent, merge the `metrics.metrics_collected.jmx` block
from `amazon-cloudwatch-agent-jmx.json` into the existing config file
(`/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json`), then:

    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

## Deploy — option B: SSM Parameter Store (recommended IaC)

Store this config in SSM and have the host fetch it. Put the parameter in a host/project
stack (NOT in the alarm modules):

    resource "aws_ssm_parameter" "cwagent_jmx" {
      name  = "/cloudwatch-agent/jmx/${var.project}-${var.env}"
      type  = "String"
      value = file("${path.module}/../../../cwagent/jmx/amazon-cloudwatch-agent-jmx.json")
      tags  = var.common_tags
    }

On the host:

    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -c ssm:/cloudwatch-agent/jmx/<project>-<env> -s

## Deploy — option C: SSM document / association

For fleet automation, push the config to instances tagged as Java hosts via an SSM
association running `amazon-cloudwatch-agent-ctl ... -c ssm:<param>`. Not implemented
here — left to host provisioning.

## Verify metrics are flowing

    aws cloudwatch list-metrics --namespace CWAgent \
      --metric-name jvm.memory.heap.used --dimensions Name=InstanceId,Value=<id>
```

- [ ] **Step 4: Commit**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git add cwagent/jmx
git commit -m "feat(jmx): add CloudWatch Agent JMX/JVM config artifact + deploy guide"
```

---

## Task 4: JMX alarm library module

**Files:**
- Create: `modules/cloudwatch/metrics-alarm/jmx/variables.tf`
- Create: `modules/cloudwatch/metrics-alarm/jmx/outputs.tf`
- Create: `modules/cloudwatch/metrics-alarm/jmx/main.tf`

**Interfaces:**
- Consumes: the metric contract from Task 3 (namespace `CWAgent`, dimension `InstanceId`, JVM metric names).
- Produces: module at `modules/cloudwatch/metrics-alarm/jmx` with inputs `project`, `env`, `resources` (list of `{name, enabled?, overrides?}` where `name` is the EC2 Name tag), `sns_topic_arns`, `default_heap_threshold` (number, default 85), `default_gc_time_threshold_ms` (number, default 6000), `common_tags`. Outputs `alarm_arns`/`alarm_names` keyed `"<name>:heap_used"` and `"<name>:gc_time"`.

- [ ] **Step 1: Write `variables.tf` and `outputs.tf` (outputs reference not-yet-created resources)**

`modules/cloudwatch/metrics-alarm/jmx/variables.tf`:
```hcl
variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of EC2 hosts (by Name tag) running a JMX-exposed Java app"
  type = list(object({
    name    = string
    enabled = optional(bool, true)
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
    error_message = "overrides.heap_threshold must be between 0 and 100 inclusive, or omitted."
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
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs mapped by severity"
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  validation {
    condition     = alltrue([for k in ["WARN", "ERROR", "CRIT"] : can(regex("^arn:aws:sns:", var.sns_topic_arns[k]))])
    error_message = "sns_topic_arns values must be SNS ARNs (starting with arn:aws:sns:)."
  }
}

variable "default_heap_threshold" {
  description = "Default threshold (percent) for JVM heap used"
  type        = number
  default     = 85
}

variable "default_gc_time_threshold_ms" {
  description = "Default threshold (milliseconds of GC per minute) for jvm.gc.collections.elapsed"
  type        = number
  default     = 6000
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
```

`modules/cloudwatch/metrics-alarm/jmx/outputs.tf`:
```hcl
output "alarm_arns" {
  description = "Map of <resource-key>:<metric-id> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:heap_used" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:gc_time" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-id> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:heap_used" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:gc_time" => v.alarm_name }
  )
}
```

- [ ] **Step 2: Run validate to verify it fails**

```bash
cd modules/cloudwatch/metrics-alarm/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false && terraform validate"
```
Expected: FAIL — `Reference to undeclared resource ... aws_cloudwatch_metric_alarm.heap_used`.

- [ ] **Step 3: Write `main.tf`**

`modules/cloudwatch/metrics-alarm/jmx/main.tf`:
```hcl
#------------------------------------------------------------------------------
# JMX / JVM Monitoring Module
# Alarms on CloudWatch-Agent-emitted JVM metrics (namespace CWAgent, dim InstanceId).
# See cwagent/jmx/ for the agent config that produces these metrics.
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

  default_severities = {
    heap_used = "WARN"
    gc_time   = "WARN"
  }
}

#------------------------------------------------------------------------------
# Resolve EC2 instance IDs from Name tag (same pattern as the EC2 module).
#------------------------------------------------------------------------------

data "aws_instances" "by_name" {
  for_each = local.jmx_resources

  filter {
    name   = "tag:Name"
    values = [each.value.name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

check "jmx_name_tag_uniqueness" {
  assert {
    condition = alltrue([
      for k, d in data.aws_instances.by_name : length(d.ids) == 1
    ])
    error_message = "Every JMX resource must have exactly one running/stopped instance with a matching Name tag. Check: ${join(", ", [for k, d in data.aws_instances.by_name : "${k}=${length(d.ids)}" if length(d.ids) != 1])}"
  }
}

data "aws_instance" "this" {
  for_each = local.jmx_resources

  filter {
    name   = "tag:Name"
    values = [each.value.name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

#------------------------------------------------------------------------------
# Heap used (%) — metric math 100 * used / max
#------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "heap_used" {
  for_each = {
    for k, v in local.jmx_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "heap_used")
  }

  alarm_name = "${local.name_prefix}-[${each.value.name}]-HeapUsedPercent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.heap_used)}]-${coalesce(
    try(each.value.overrides.description, null),
    "${local.name_prefix}-[${each.value.name}]-HeapUsedPercent is in ALARM state"
  )}"

  comparison_operator = "GreaterThanThreshold"
  threshold = coalesce(
    try(each.value.overrides.heap_threshold, null),
    var.default_heap_threshold
  )
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  metric_query {
    id          = "e1"
    expression  = "100*m1/m2"
    label       = "HeapUsedPercent"
    return_data = true
  }

  metric_query {
    id = "m1"
    metric {
      namespace   = "CWAgent"
      metric_name = "jvm.memory.heap.used"
      stat        = "Average"
      period      = 60
      dimensions  = { InstanceId = data.aws_instance.this[each.key].id }
    }
  }

  metric_query {
    id = "m2"
    metric {
      namespace   = "CWAgent"
      metric_name = "jvm.memory.heap.max"
      stat        = "Average"
      period      = 60
      dimensions  = { InstanceId = data.aws_instance.this[each.key].id }
    }
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

#------------------------------------------------------------------------------
# GC time (ms per minute) — DIFF of the cumulative jvm.gc.collections.elapsed counter.
# A JVM restart resets the counter -> negative DIFF -> never breaches (alarm is '>').
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
    expression  = "DIFF(m1)"
    label       = "GcTimeMsPerMinute"
    return_data = true
  }

  metric_query {
    id = "m1"
    metric {
      namespace   = "CWAgent"
      metric_name = "jvm.gc.collections.elapsed"
      stat        = "Maximum"
      period      = 60
      dimensions  = { InstanceId = data.aws_instance.this[each.key].id }
    }
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

- [ ] **Step 4: Run validate to verify it passes**

```bash
cd modules/cloudwatch/metrics-alarm/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false && terraform validate"
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git add modules/cloudwatch/metrics-alarm/jmx
git commit -m "feat(metrics): add JMX/JVM heap + GC-time alarm module"
```

---

## Task 5: Wire JMX into the project stack + config examples

**Files:**
- Modify: `stacks/projects/billing/dev/variables.tf` (add `jmx_resources`)
- Modify: `stacks/projects/billing/dev/main.tf` (add `module "jmx_alarms"`)
- Modify: `stacks/projects/billing/dev/config.yaml.example` (add `jmx:` block)
- Modify: `stacks/projects/billing/dev/terraform.tfvars.example` (add `jmx_resources`)

**Interfaces:**
- Consumes: the `jmx` module from Task 4.
- Produces: `var.jmx_resources` and `module.jmx_alarms` in billing/dev.

- [ ] **Step 1: Add the `jmx_resources` variable**

Append to `stacks/projects/billing/dev/variables.tf`:
```hcl
variable "jmx_resources" {
  description = "EC2 hosts (by Name tag) running a JMX-exposed Java app to monitor."
  type = list(object({
    name    = string
    enabled = optional(bool, true)
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

- [ ] **Step 2: Add the module block**

Append to `stacks/projects/billing/dev/main.tf`:
```hcl
module "jmx_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/jmx"
  count  = length(var.jmx_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.jmx_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}
```

- [ ] **Step 3: Add the `jmx:` example block to `config.yaml.example`**

Insert under the `resources:` map in `stacks/projects/billing/dev/config.yaml.example`:
```yaml
  # JVM/JMX on EC2 Java hosts (by Name tag). Requires the cwagent JMX config from
  # cwagent/jmx/ on the host. valid jmx ids: heap_used, gc_time
  jmx:
    - name: billing-java-app-1
    - name: billing-java-app-2
      overrides:
        heap_threshold:       90
        gc_time_threshold_ms: 12000   # 12s of GC per minute
        severity:             ERROR
```

- [ ] **Step 4: Add `jmx_resources` to `terraform.tfvars.example`**

Append to `stacks/projects/billing/dev/terraform.tfvars.example`:
```hcl
jmx_resources = [
  { name = "billing-java-app-1" },
  {
    name      = "billing-java-app-2"
    overrides = { heap_threshold = 90, gc_time_threshold_ms = 12000, severity = "ERROR" }
  },
]
```

- [ ] **Step 5: Validate fmt + module resolution**

```bash
cd stacks/projects/billing/dev
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform fmt -check && terraform init -backend=false 2>&1 | tail -5"
```
Expected: `fmt -check` clean; `../../../../modules/cloudwatch/metrics-alarm/jmx` resolves.

- [ ] **Step 6: Commit**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git add stacks/projects/billing/dev
git commit -m "feat(metrics): wire JMX alarms into billing/dev stack + examples"
```

---

## Task 6: JVM dashboard — module (single source) + importable artifact

**Files:**
- Create: `modules/cloudwatch/dashboard/jmx/variables.tf`
- Create: `modules/cloudwatch/dashboard/jmx/main.tf`
- Create: `modules/cloudwatch/dashboard/jmx/outputs.tf`
- Create: `dashboards/jmx-jvm.json`
- Create: `dashboards/README.md`

**Interfaces:**
- Consumes: the metric contract from Task 3 (namespace `CWAgent`, dim `InstanceId`, JVM metric names).
- Produces: module at `modules/cloudwatch/dashboard/jmx` with inputs `project`, `env`, `region` (string), `instances` (list of `{name, instance_id}`); creates `aws_cloudwatch_dashboard` and outputs `dashboard_json` (string) and `dashboard_name`. Static artifact `dashboards/jmx-jvm.json` mirrors the rendered body for console import.

- [ ] **Step 1: Write `variables.tf` and `outputs.tf` (outputs reference not-yet-created resource)**

`modules/cloudwatch/dashboard/jmx/variables.tf`:
```hcl
variable "project" {
  description = "Project name for dashboard naming"
  type        = string
}

variable "env" {
  description = "Environment name for dashboard naming"
  type        = string
}

variable "region" {
  description = "Region the JVM metrics live in (widget region)"
  type        = string
}

variable "instances" {
  description = "Java hosts to chart: friendly name + resolved EC2 InstanceId"
  type = list(object({
    name        = string
    instance_id = string
  }))
}
```

`modules/cloudwatch/dashboard/jmx/outputs.tf`:
```hcl
output "dashboard_name" {
  description = "Name of the created CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.jmx.dashboard_name
}

output "dashboard_json" {
  description = "Rendered dashboard body (import this JSON into the console to reproduce the dashboard)."
  value       = aws_cloudwatch_dashboard.jmx.dashboard_body
}
```

- [ ] **Step 2: Run validate to verify it fails**

```bash
cd modules/cloudwatch/dashboard/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false && terraform validate"
```
Expected: FAIL — `Reference to undeclared resource ... aws_cloudwatch_dashboard.jmx`.

- [ ] **Step 3: Write `main.tf` (build the body with `jsonencode` — single source of truth)**

`modules/cloudwatch/dashboard/jmx/main.tf`:
```hcl
#------------------------------------------------------------------------------
# JVM / JMX CloudWatch dashboard. Body built with jsonencode (single source);
# `dashboard_json` output is the same body for console import (dashboards/jmx-jvm.json).
# Three widgets per instance: heap (used % + bytes), GC time/min, threads + classes.
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
  widgets = flatten([
    for idx, inst in var.instances : [
      {
        type   = "metric"
        x      = 0
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${inst.name} — Heap"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ expression = "100*m1/m2", label = "Heap used %", id = "e1" }],
            ["CWAgent", "jvm.memory.heap.used", "InstanceId", inst.instance_id, { id = "m1", visible = false }],
            ["CWAgent", "jvm.memory.heap.max", "InstanceId", inst.instance_id, { id = "m2", visible = false }],
            ["CWAgent", "jvm.memory.heap.committed", "InstanceId", inst.instance_id, { label = "Heap committed (bytes)", yAxis = "right" }]
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
          title  = "${inst.name} — GC time (ms/min)"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ expression = "DIFF(m1)", label = "GC time ms/min", id = "e1" }],
            ["CWAgent", "jvm.gc.collections.elapsed", "InstanceId", inst.instance_id, { id = "m1", stat = "Maximum", visible = false }],
            [{ expression = "DIFF(m2)", label = "GC cycles/min", id = "e2", yAxis = "right" }],
            ["CWAgent", "jvm.gc.collections.count", "InstanceId", inst.instance_id, { id = "m2", stat = "Maximum", visible = false }]
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
          title  = "${inst.name} — Threads & classes"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            ["CWAgent", "jvm.threads.count", "InstanceId", inst.instance_id, { label = "Threads" }],
            ["CWAgent", "jvm.classes.loaded", "InstanceId", inst.instance_id, { label = "Classes loaded", yAxis = "right" }]
          ]
        }
      }
    ]
  ])
}

resource "aws_cloudwatch_dashboard" "jmx" {
  dashboard_name = "${var.project}-${var.env}-JVM"
  dashboard_body = jsonencode({ widgets = local.widgets })
}
```

- [ ] **Step 4: Run validate to verify it passes**

```bash
cd modules/cloudwatch/dashboard/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false && terraform validate"
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Write the importable static artifact (one instance, placeholder id)**

`dashboards/jmx-jvm.json` (a one-instance snapshot of the module's rendered body; replace `i-PLACEHOLDER` / region before import):
```json
{
  "widgets": [
    {
      "type": "metric",
      "x": 0, "y": 0, "width": 8, "height": 6,
      "properties": {
        "title": "java-app — Heap",
        "region": "ap-northeast-1",
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "yAxis": { "left": { "min": 0 } },
        "metrics": [
          [ { "expression": "100*m1/m2", "label": "Heap used %", "id": "e1" } ],
          [ "CWAgent", "jvm.memory.heap.used", "InstanceId", "i-PLACEHOLDER", { "id": "m1", "visible": false } ],
          [ "CWAgent", "jvm.memory.heap.max", "InstanceId", "i-PLACEHOLDER", { "id": "m2", "visible": false } ],
          [ "CWAgent", "jvm.memory.heap.committed", "InstanceId", "i-PLACEHOLDER", { "label": "Heap committed (bytes)", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 0, "width": 8, "height": 6,
      "properties": {
        "title": "java-app — GC time (ms/min)",
        "region": "ap-northeast-1",
        "view": "timeSeries",
        "period": 60,
        "yAxis": { "left": { "min": 0 } },
        "metrics": [
          [ { "expression": "DIFF(m1)", "label": "GC time ms/min", "id": "e1" } ],
          [ "CWAgent", "jvm.gc.collections.elapsed", "InstanceId", "i-PLACEHOLDER", { "id": "m1", "stat": "Maximum", "visible": false } ],
          [ { "expression": "DIFF(m2)", "label": "GC cycles/min", "id": "e2", "yAxis": "right" } ],
          [ "CWAgent", "jvm.gc.collections.count", "InstanceId", "i-PLACEHOLDER", { "id": "m2", "stat": "Maximum", "visible": false } ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 16, "y": 0, "width": 8, "height": 6,
      "properties": {
        "title": "java-app — Threads & classes",
        "region": "ap-northeast-1",
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "yAxis": { "left": { "min": 0 } },
        "metrics": [
          [ "CWAgent", "jvm.threads.count", "InstanceId", "i-PLACEHOLDER", { "label": "Threads" } ],
          [ "CWAgent", "jvm.classes.loaded", "InstanceId", "i-PLACEHOLDER", { "label": "Classes loaded", "yAxis": "right" } ]
        ]
      }
    }
  ]
}
```

- [ ] **Step 6: Verify the static artifact is valid JSON**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
python3 -m json.tool dashboards/jmx-jvm.json > /dev/null && echo "valid json"
```
Expected: `valid json`.

- [ ] **Step 7: Write `dashboards/README.md`**

`dashboards/README.md`:
```markdown
# Dashboards

## jmx-jvm.json — JVM / JMX dashboard

Per-instance JVM view (heap used % + bytes, GC time/min, GC cycles/min, threads, classes)
sourced from the CloudWatch Agent JMX metrics (see `cwagent/jmx/`).

Two ways to use it:

### Import the static JSON (console)
`dashboards/jmx-jvm.json` is a one-instance snapshot. Replace `i-PLACEHOLDER` with the
real InstanceId and the `region` fields, then create the dashboard:

    aws cloudwatch put-dashboard --dashboard-name my-jvm \
      --dashboard-body file://dashboards/jmx-jvm.json

Or paste it into **CloudWatch → Dashboards → Create → Actions → View/edit source**.

### Terraform (multi-instance, single source of truth)
Use the module — it builds the body for all instances and creates the dashboard:

    module "jvm_dashboard" {
      source = "../../../../modules/cloudwatch/dashboard/jmx"
      project   = var.project
      env       = var.env
      region    = var.aws_region
      instances = [
        { name = "billing-java-app-1", instance_id = "i-aaaa" },
        { name = "billing-java-app-2", instance_id = "i-bbbb" },
      ]
    }

To regenerate this static file from the module after a layout change:

    terraform -chdir=<stack> output -raw <module>_dashboard_json > dashboards/jmx-jvm.json
```

- [ ] **Step 8: Commit**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git add modules/cloudwatch/dashboard/jmx dashboards
git commit -m "feat(jmx): add JVM dashboard module + importable static dashboard"
```

---

## Task 7: Docs + repo-wide format/validate sweep

**Files:**
- Modify: `CLAUDE.md` (architecture list, EFS + JMX special behaviors, dashboard module)

**Interfaces:**
- Consumes: all prior tasks.
- Produces: updated project docs; repo formatted.

- [ ] **Step 1: Update the resource-type count and special-behaviors in `CLAUDE.md`**

In `CLAUDE.md`, change the architecture intro from "11 AWS resource types" to "13 AWS resource types". Add to the `### Special Module Behaviors` list:
```markdown
- **EFS**: Identified by `file_system_id` (`fs-xxxx`) directly — no Name-tag lookup (the AWS provider has no tag-filtered EFS data source). The single `throughput_util` alarm is the repo's only **metric-math** alarm: throughput utilization % = `Sum(MeteredIOBytes)/PERIOD ÷ Average(PermittedThroughput)`. Watched over a long span (default `period=3600` × `evaluation_periods=6` = 6h sustained ≥80%) to catch a creeping throughput-bottleneck trend rather than short spikes; `period`/`evaluation_periods`/`throughput_util_threshold` are overridable. `treat_missing_data="notBreaching"` (idle EFS must not alarm).
- **JMX**: Heap/GC alarms for Java apps on EC2, by Name tag (same InstanceId lookup + `check {}` as EC2). Depends on the CloudWatch Agent JMX config in `cwagent/jmx/` (contract: namespace `CWAgent`, dimension `InstanceId`, OTel metric names `jvm.*`). `heap_used` = metric-math `100*used/max` (default 85%); `gc_time` = `DIFF(jvm.gc.collections.elapsed)` ms/min (default 6000). A JVM restart resets the GC counter → negative `DIFF` → never breaches.
```

Also add a sentence to the `### Severity → SNS Routing` / dashboard context (end of architecture section):
```markdown
### Dashboards

`modules/cloudwatch/dashboard/jmx/` builds a per-instance JVM dashboard via `jsonencode` and exposes the body as the `dashboard_json` output; `dashboards/jmx-jvm.json` is an importable one-instance snapshot of the same layout. The cwagent JMX config that feeds it lives in `cwagent/jmx/` (outside the alarm modules — this repo manages alarms/dashboards, not compute).
```

- [ ] **Step 2: Run repo-wide format**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  fmt -recursive
```
Expected: prints any reformatted file paths (ideally none if earlier tasks ran fmt).

- [ ] **Step 3: Validate all three new modules pass**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
for m in modules/cloudwatch/metrics-alarm/efs modules/cloudwatch/metrics-alarm/jmx modules/cloudwatch/dashboard/jmx; do
  echo "== $m ==";
  ( cd "$m" && podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
      sh -c "terraform init -backend=false >/dev/null && terraform validate" );
done
```
Expected: `Success! The configuration is valid.` for all three.

- [ ] **Step 4: Commit**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git add -A
git commit -m "docs: document EFS, JMX modules and JVM dashboard in CLAUDE.md"
```

---

## Self-Review Notes

- **Spec coverage:** Part A (EFS module) → Tasks 1–2. Part B1 (cwagent config) → Task 3. Part B2 (JMX alarm module) → Tasks 4–5. Part B3 (dashboard, both forms) → Task 6. Cross-cutting (CLAUDE.md, fmt/validate) → Task 7. All spec sections mapped.
- **Type consistency:** metric ids `throughput_util`, `heap_used`, `gc_time` are identical across each module's `disabled_alarms` validation, `for_each` filter, output keys, and CLAUDE.md. Dashboard module I/O (`instances` = list of `{name, instance_id}`, outputs `dashboard_json`/`dashboard_name`) matches the README usage snippet.
- **No placeholders:** all file contents are complete; `i-PLACEHOLDER` in the static dashboard is an intentional, documented substitution token, not an unfinished step.
- **Known environment caveat:** stack-level full `terraform validate` (Tasks 2/5) needs remote-state data sources + creds and is deferred to the work machine; the plan only asserts `fmt`/module-resolution locally, consistent with the two-machine workflow.
