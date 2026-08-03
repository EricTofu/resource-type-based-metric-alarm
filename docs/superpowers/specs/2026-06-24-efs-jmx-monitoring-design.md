# EFS throughput-trend alarms + JVM/JMX monitoring — Design

Date: 2026-06-24
Branch: `feat/efs-and-jmx-monitoring`

## Motivation

An EFS file system in **Bursting Throughput** mode became a latency bottleneck in a
prior project: throughput climbed and burst credits depleted over *hours* before
anything throttled, then cascaded. The file system has since moved to **Elastic**
mode, but we want a standing early-warning signal on **throughput utilization trend**
so a creeping climb toward the ceiling is visible *before* it bites. This mirrors the
lesson from the 2026-05-27 incident: the honest signal is the *sustained* state over a
long span, not a momentary spike.

Separately, the Java applications running on EC2 expose **JMX on `localhost:9999`**. We
want JVM observability — heap usage and time-in-GC — wired through the CloudWatch Agent,
with alarms and an importable dashboard, so JVM pressure (the leading indicator of the
container-hang failure mode) is caught early.

## Scope

Two independent but related additions, delivered together on one branch:

- **Part A** — EFS alarm library module (throughput-utilization trend).
- **Part B** — JVM/JMX monitoring: cwagent config artifact, JMX alarm library module,
  and a CloudWatch dashboard (both an importable JSON artifact and a Terraform-managed
  resource).

Out of scope: provisioning compute, installing the CloudWatch Agent, or managing the
Java apps. This repo manages **alarms and dashboards**; the agent config is delivered as
an artifact that host/work-machine provisioning applies.

---

## Part A — EFS library module

Path: `modules/cloudwatch/metrics-alarm/efs/`

Follows the standard module pattern: `variables.tf` / `main.tf` / `outputs.tf`, every
input has a `validation {}` block, severity → SNS routing via `var.sns_topic_arns`,
threshold resolution via a `coalesce()` chain (per-resource override → module default).

### Identity

Each resource is keyed by **`file_system_id`** (`fs-xxxx`) — given directly, the way
CloudFront takes `distribution_id`. The CloudWatch dimension `FileSystemId` is exactly
this value, so no data-source lookup is needed (and AWS's Terraform provider has no
tag-filtered EFS data source, so Name-tag resolution is deliberately avoided). An
optional `name` provides a friendly label for the alarm name.

### `resources` type

```hcl
list(object({
  file_system_id = string                       # fs-xxxxxxxx
  name           = optional(string)             # friendly name for alarm naming
  enabled        = optional(bool, true)
  overrides = optional(object({
    severity                  = optional(string) # WARN | ERROR | CRIT
    description               = optional(string)
    throughput_util_threshold = optional(number) # percent, 0..100
    period                    = optional(number) # seconds; default 3600
    evaluation_periods        = optional(number) # default 6
    disabled_alarms           = optional(set(string), []) # valid id: throughput_util
  }), {})
}))
```

Validations: `file_system_id` matches `^fs-`; `severity` ∈ {WARN,ERROR,CRIT} or omitted;
`throughput_util_threshold` in `[0,100]` or omitted; `disabled_alarms` ⊆ {`throughput_util`}.

### The alarm — `throughput_util` (metric math)

Introduces the **first metric-math alarm** in this repo (justified: throughput
utilization is not a published metric). Per the AWS EFS "Throughput utilization (%)"
definition:

```
m1 = AWS/EFS MeteredIOBytes   (Sum)      dimensions = { FileSystemId }
m2 = AWS/EFS PermittedThroughput (Average) dimensions = { FileSystemId }
e1 = 100 * (m1 / PERIOD(m1)) / m2   # metered MiBps ÷ permitted MiBps, return_data = true
```

- `comparison_operator = GreaterThanThreshold`
- `threshold` = coalesce(override, `var.default_throughput_util_threshold` = **80**)
- `period` = coalesce(override, **3600**); `evaluation_periods` = coalesce(override, **6**);
  `datapoints_to_alarm` = same as evaluation_periods → **6h sustained** by default.
- Default severity **WARN**; `treat_missing_data = "notBreaching"` (an idle EFS emits low
  metered bytes; absence of load must not alarm).

Both `m1` and `m2` use the resolved `period`. In Elastic mode `PermittedThroughput`
reflects the elastic ceiling, so the same expression tracks "how close are we to the
limit" without code changes.

### Outputs

`alarm_arns` / `alarm_names`, maps keyed `"<file_system_id>:throughput_util"`.

### Stack wiring

- New `efs_resources` variable in the project stack `variables.tf` (mirrors the module
  `resources` type).
- New `module "efs_alarms"` block in `main.tf` with
  `count = length(var.efs_resources) > 0 ? 1 : 0`, passing `project/env/resources/
  sns_topic_arns/common_tags`.
- New `efs:` block in `config.yaml.example` and `terraform.tfvars.example` with a worked
  example (a default file system + one with a tightened threshold / longer window).

---

## Part B — JVM/JMX monitoring

### B1. CloudWatch Agent JMX config artifact

Path: `cwagent/jmx/` (outside the alarm modules — config lives separate from alarms).

`amazon-cloudwatch-agent-jmx.json`:

```jsonc
{
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"]],
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

`README.md` covers:

- Prerequisite: amazon-cloudwatch-agent version with JMX support; Java exposes JMX on
  `localhost:9999` (no auth/SSL for localhost, or document the auth flags).
- **Merge** path: how to fold this `jmx` block into an existing agent config and restart
  (`amazon-cloudwatch-agent-ctl -a fetch-config ... -s`).
- **SSM Parameter Store** path (option 2, recommended IaC): a copy-pasteable
  `aws_ssm_parameter` snippet holding this JSON (lives in a project/host stack, *not* the
  alarm modules) + `amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c ssm:<param> -s`.
- **SSM document/association** path (option 3): noted as the more-automated push to tagged
  instances, with a pointer; not implemented here.

**Metric/dimension contract** (the alarm module and dashboard depend on this): namespace
`CWAgent`, dimension `InstanceId`, OTel metric names as listed above.

### B2. JMX alarm library module

Path: `modules/cloudwatch/metrics-alarm/jmx/`

Standard module pattern. **Identity by Name tag**, reusing the EC2 module's approach:
`data.aws_instances.by_name` + `data.aws_instance.this` + a `check {}` block warning at
plan time when a Name tag matches zero or multiple instances. Resolves `InstanceId`,
which is the dimension the agent emits.

#### `resources` type

```hcl
list(object({
  name    = string                 # EC2 Name tag (the Java host)
  enabled = optional(bool, true)
  overrides = optional(object({
    severity            = optional(string)
    description         = optional(string)
    heap_threshold      = optional(number)  # percent, 0..100
    gc_time_threshold_ms = optional(number) # ms-in-GC per minute
    disabled_alarms     = optional(set(string), []) # valid ids: heap_used, gc_time
  }), {})
}))
```

#### Alarms

1. **`heap_used`** — metric math `100 * used / max`:
   ```
   m1 = CWAgent jvm.memory.heap.used (Average) dims { InstanceId }
   m2 = CWAgent jvm.memory.heap.max  (Average) dims { InstanceId }
   e1 = 100 * m1 / m2   (return_data)
   ```
   `>` threshold, default **85** (`var.default_heap_threshold`), `period=60`,
   `evaluation_periods=3`, `datapoints_to_alarm=3`, severity **WARN**,
   `treat_missing_data="notBreaching"`.

2. **`gc_time`** — time spent in GC per minute via `DIFF` of the cumulative counter:
   ```
   m1 = CWAgent jvm.gc.collections.elapsed (Maximum) dims { InstanceId }, period=60
   e1 = DIFF(m1)   (return_data)   # ms of GC in the last minute
   ```
   `>` threshold, default **6000 ms/min** (= 10% of wall time;
   `var.default_gc_time_threshold_ms`), `evaluation_periods=3`, `datapoints_to_alarm=3`,
   severity **WARN**, `treat_missing_data="notBreaching"`. A JVM restart resets the
   cumulative counter, producing a negative `DIFF`; since the alarm is
   `GreaterThanThreshold`, negatives never breach — no special handling needed.

#### Outputs

`alarm_arns` / `alarm_names`, keyed `"<name>:heap_used"` and `"<name>:gc_time"`.

#### Stack wiring

`jmx_resources` variable + `module "jmx_alarms"` block (count-gated) + `jmx:` block in
`config.yaml.example` and `terraform.tfvars.example`.

### B3. Dashboard — both artifact and Terraform

A single Go-template / `templatefile` source feeds both delivery forms so they never
drift.

- **`dashboards/jmx-jvm.json`** — importable static dashboard (console "Import" / `aws
  cloudwatch put-dashboard`). Widgets: heap used/committed/max, heap used %, GC time/min,
  GC cycles/min, thread count, classes loaded. Includes a placeholder `InstanceId` and a
  short note in `dashboards/README.md` on substituting real instance IDs.
- **`modules/cloudwatch/dashboard/jmx/`** — a module exposing `project`, `env`,
  `instances` (list of `{ name, instance_id }` or Name tags resolved like B2), rendering
  `aws_cloudwatch_dashboard` via `templatefile` from the shared template. Applied in a
  stack alongside the alarms.

---

## Cross-cutting

- **CLAUDE.md** updated: two new resource types in the architecture list; an EFS note
  (metric-math alarm, `file_system_id` identity, 6h-sustained default window); a JMX note
  (agent contract: namespace `CWAgent`, `InstanceId` dimension, OTel metric names; Name-tag
  identity; `gc_time` DIFF behavior); the new dashboard module.
- **Validation**: every new module validated with
  `terraform init -backend=false && terraform validate`, run via containerized terraform
  (`podman run ... docker.io/hashicorp/terraform:1.10`, `:Z` on Fedora). `terraform fmt
  -recursive` from repo root.

## Default values summary

| Knob | Default | Severity |
|---|---|---|
| EFS `throughput_util_threshold` | 80 % | WARN |
| EFS window | 3600 s × 6 (6 h sustained) | — |
| JMX `heap_threshold` | 85 % | WARN |
| JMX `gc_time_threshold_ms` | 6000 ms/min | WARN |

All thresholds, windows, and severities are per-resource overridable; alarms are opt-out
via `disabled_alarms`.

## Testing / acceptance

- Each new module: `terraform validate` passes; `for_each`/`disabled_alarms` filtering and
  validation blocks behave (bad severity / out-of-range threshold / unknown disabled id
  are rejected).
- EFS metric-math alarm references `MeteredIOBytes` + `PermittedThroughput` with correct
  stats and `PERIOD()` math.
- JMX alarms reference the exact metric names the cwagent config emits (contract check).
- Dashboard JSON is valid (`aws cloudwatch put-dashboard --dashboard-body` dry sanity, or
  JSON parse) and the Terraform dashboard module renders from the same template.
- config.yaml / tfvars examples include working `efs:` and `jmx:` blocks.
