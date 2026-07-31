# Alerting Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reclassify all alarms against what the severity tiers actually do, reinstate `gc_time` as a delta gauge query, lengthen the `heap_used` window, and re-enable the ALB latency alarm.

**Architecture:** Every alarm module owns a `local.default_severities` map keyed by alarm resource label; severity reclassification is edits to those maps, which flow through to `alarm_actions`/`ok_actions` and the `[SEVERITY]-` description prefix with no resource replacement. Two alarms change shape (`gc_time` reinstated, `heap_used` window), one is re-enabled from comments (`target_response_time`). No stack wiring changes.

**Tech Stack:** Terraform ≥ 1.5 (run containerised), AWS provider ≥ 5.0, CloudWatch Metrics Insights, bash + python3 preflight scripts.

**Spec:** `docs/superpowers/specs/2026-07-31-alerting-policy-design.md`

## Global Constraints

- Terraform is **not installed on the host**. Every terraform command runs containerised:
  `podman run --rm -v "$PWD":/w:Z -w /w docker.io/hashicorp/terraform:1.10 <args>` (the `:Z` suffix is required on Fedora). python3 **is** on the host.
- `terraform fmt -recursive` must be clean before every commit; run it from the repo root.
- Library modules validate with no backend: `init -backend=false` then `validate`, run **inside the module directory**.
- Never commit a `*.tfvars` file. `config.yaml`/`*.example` files are fine.
- Alarm severity is set **only** via each module's `local.default_severities`; never hardcode a severity in a resource.
- Alarm names are `ForceNew`. No task in this plan may change an `alarm_name` string.
- Commit messages end with: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- Current branch is `feat/asg-fleet-alarms`; all work lands there.

## Verification model (read before Task 1)

Terraform has no unit-test framework here, so each task's "failing test" is an **assertion command that must fail before the change and pass after**. Two forms are used:

1. `grep -c` / `grep -q` assertions against module source, with the exact expected output stated.
2. `terraform validate` inside the changed module.

Both are cheap and deterministic. Where a real AWS check is possible it is called out as **optional (work machine)** and is never a gate for the commit.

---

### Task 1: Land the pending working-tree changes

The working tree currently holds the `ORDER BY` fix, the `gc_time` removal, the config guard, and the docs that go with them — all validated. Commit them as-is. Task 2 then reinstates `gc_time` in the corrected form as its own commit, so the history reads: removed because `PutMetricAlarm` rejected `DIFF`, reinstated once the metric was found to be a delta already. Do not attempt to untangle this into a single "correct" commit — the two-step history is the honest record and is far less error-prone than partial staging.

**Files:**
- Modify (already edited, uncommitted): `CLAUDE.md`, `docs/superpowers/specs/2026-07-30-module-identity-boundaries-design.md`, `modules/cloudwatch/metrics-alarm/asg/main.tf`, `modules/cloudwatch/metrics-alarm/jmx/{main,outputs,variables}.tf`, `stacks/projects/billing/dev/{config.yaml.example,terraform.tfvars.example,variables.tf}`
- Create (already written, untracked): `stacks/projects/billing/dev/config_guard.tf.example`

**Interfaces:**
- Produces: four alarm queries carrying `ORDER BY AVG() DESC` (jmx `heap_used`; asg `fleet_cpu`, `fleet_memory`, `fleet_disk`); a jmx module with no `gc_time`; `config_guard.tf.example` for YAML-wired leaves.

- [ ] **Step 1: Confirm the tree is what this task expects**

Run:
```bash
git status --short
```
Expected exactly (order may vary):
```
 M CLAUDE.md
 M docs/superpowers/specs/2026-07-30-module-identity-boundaries-design.md
 M modules/cloudwatch/metrics-alarm/asg/main.tf
 M modules/cloudwatch/metrics-alarm/jmx/main.tf
 M modules/cloudwatch/metrics-alarm/jmx/outputs.tf
 M modules/cloudwatch/metrics-alarm/jmx/variables.tf
 M stacks/projects/billing/dev/config.yaml.example
 M stacks/projects/billing/dev/terraform.tfvars.example
 M stacks/projects/billing/dev/variables.tf
?? stacks/projects/billing/dev/config_guard.tf.example
```
If anything else appears, STOP and ask — this plan assumes that exact state.

- [ ] **Step 2: Assert every multi-series alarm query orders**

Run:
```bash
grep -c "GROUP BY InstanceId ORDER BY AVG() DESC" \
  modules/cloudwatch/metrics-alarm/jmx/main.tf \
  modules/cloudwatch/metrics-alarm/asg/main.tf
```
Expected: `...jmx/main.tf:1` and `...asg/main.tf:3`.

- [ ] **Step 3: Validate both changed modules**

Run:
```bash
for m in jmx asg; do
  podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/$m":/w:Z -w /w \
    docker.io/hashicorp/terraform:1.10 init -backend=false -no-color >/dev/null
  podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/$m":/w:Z -w /w \
    docker.io/hashicorp/terraform:1.10 validate -no-color
done
```
Expected: `Success! The configuration is valid.` twice.

- [ ] **Step 4: Check formatting**

Run: `podman run --rm -v "$PWD":/w:Z -w /w docker.io/hashicorp/terraform:1.10 fmt -recursive -check -no-color`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -F - <<'EOF'
fix(alarms): ORDER BY on every multi-series query; drop gc_time

PutMetricAlarm rejects any expression returning multiple time series
unless it is a Metrics Insights expression carrying ORDER BY:

  ValidationError: Metrics expression that return multi time series are
  only allowed for MetricsInsights expression with an ORDER BY clause

jmx heap_used and asg fleet_cpu/fleet_memory/fleet_disk all used
GROUP BY InstanceId with no ORDER BY. They pass terraform validate and
pass get-metric-data, and fail only at apply — one of them did.
fleet_in_service_capacity is unaffected (SUM, no GROUP BY, one series).

gc_time is removed rather than fixed: its return_data expression is
DIFF(q1), metric math wrapping a multi-series query, which the same rule
rejects no matter where ORDER BY goes. RATE() fails identically. This
resolves the 2026-07-30 spec's blocking verify item 2 in the negative.

Also adds config_guard.tf.example: a check block for YAML-wired leaves
that names any resources: key no module block reads, after jmx sat inert
on the work leaf for exactly that reason.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Reinstate `gc_time` as a delta gauge query

The agent applies `cumulativetodelta/jmx` before publishing, so `jvm_gc_collections_elapsed` arrives already as **ms of GC per 60s interval** (confirmed over a 3h span in Query Studio). No metric math is needed, so the multi-series rule is satisfied by `ORDER BY` alone.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/jmx/main.tf` (replace the removal comment block)
- Modify: `modules/cloudwatch/metrics-alarm/jmx/variables.tf` (restore the override, threshold var, validation id)
- Modify: `modules/cloudwatch/metrics-alarm/jmx/outputs.tf` (both maps)
- Modify: `stacks/projects/billing/dev/variables.tf` (leaf mirror of the overrides object)
- Modify: `stacks/projects/billing/dev/config.yaml.example`, `stacks/projects/billing/dev/terraform.tfvars.example`

**Interfaces:**
- Consumes: `local.jmx_resources`, `local.pg_filter`, `local.name_prefix` from Task 1's module.
- Produces: alarm resource label `gc_time`; output keys `"<name>:GcTimeMsPerMinute"`; module input `var.default_gc_time_threshold_ms` (number, default `6000`); per-entry `overrides.gc_time_threshold_ms`; `disabled_alarms` accepts `heap_used` and `gc_time`.

- [ ] **Step 1: Write the failing assertion**

Run:
```bash
grep -q 'resource "aws_cloudwatch_metric_alarm" "gc_time"' modules/cloudwatch/metrics-alarm/jmx/main.tf \
  && echo PASS || echo FAIL
```
Expected now: `FAIL` (Task 1 removed it).

- [ ] **Step 2: Add `gc_time` back to the severity map**

In `modules/cloudwatch/metrics-alarm/jmx/main.tf`, replace:
```hcl
  default_severities = {
    heap_used = "WARN"
  }
```
with:
```hcl
  default_severities = {
    heap_used = "ERROR"
    gc_time   = "ERROR"
  }
```
(ERROR per the spec: both JVM signals are candidate leading indicators routed to chat, not the pager.)

- [ ] **Step 3: Replace the removal comment with the alarm**

In the same file, delete the entire `# GC time — REMOVED (2026-07-31).` comment block (from its opening `#---` rule to its closing `#---` rule) and put this in its place:

```hcl
#------------------------------------------------------------------------------
# GC time (ms per minute) — a plain gauge query, NOT metric math.
#
# The CloudWatch agent applies a `cumulativetodelta/jmx` processor before
# publishing (see the translated pipeline at
# /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.yaml), so
# jvm_gc_collections_elapsed reaches CloudWatch already as milliseconds of GC
# per 60s collection interval — verified over a 3h span: it rises and returns
# to 0 instead of climbing. `initial_value: 2` drops the first point.
#
# The previous DIFF(q1) form was wrong twice over: PutMetricAlarm rejects metric
# math wrapping a multi-series query, AND differencing an already-differenced
# series measures the CHANGE in GC time (acceleration), not GC time. The
# "JVM restart resets the counter -> negative DIFF -> fails safe" reasoning
# guarded against a reset that never reaches CloudWatch.
#
# SUM totals time-in-GC across the per-collector `name` series within each
# instance. The threshold is ms of GC per minute: 6000 = 10% of wall clock, the
# standard GC-overhead heuristic.
#
# CAUTION: "ms per interval" equals "ms per minute" only while the agent's
# metrics_collection_interval is 60. Halve the interval and every threshold here
# silently halves in meaning.
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
  evaluation_periods  = 5
  datapoints_to_alarm = 5

  # Five consecutive minutes, so a single stop-the-world burst does not fire it.
  # ORDER BY is required for a multi-series alarm — see heap_used above.
  metric_query {
    id          = "q1"
    return_data = true
    period      = 60
    expression  = "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '${each.value.app_name}'${local.pg_filter[each.key]} GROUP BY InstanceId ORDER BY SUM() DESC"
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

- [ ] **Step 4: Restore the module inputs**

In `modules/cloudwatch/metrics-alarm/jmx/variables.tf`, in the `resources` variable's `overrides` object, change:
```hcl
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      heap_threshold  = optional(number)
      disabled_alarms = optional(set(string), [])
    }), {})
```
to:
```hcl
    overrides = optional(object({
      severity             = optional(string)
      description          = optional(string)
      heap_threshold       = optional(number)
      gc_time_threshold_ms = optional(number)
      disabled_alarms      = optional(set(string), [])
    }), {})
```

Replace the `disabled_alarms` validation block (the one whose comment begins `# gc_time was removed 2026-07-31`) with:
```hcl
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
```

Append this variable at the end of the file:
```hcl
variable "default_gc_time_threshold_ms" {
  description = "Default threshold in milliseconds of GC per minute. 6000 = 10% of wall clock in GC, the standard GC-overhead heuristic. Assumes the agent's metrics_collection_interval is 60 — the metric is a per-interval delta."
  type        = number
  default     = 6000
}
```

- [ ] **Step 5: Restore the outputs**

In `modules/cloudwatch/metrics-alarm/jmx/outputs.tf`, change both single-map outputs back to merges:
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
```
Leave `dashboard_targets` untouched.

- [ ] **Step 6: Restore the leaf mirror and examples**

In `stacks/projects/billing/dev/variables.tf`, inside `variable "jmx_resources"`, restore `gc_time_threshold_ms = optional(number)` to the `overrides` object (matching the module's field order: `severity`, `description`, `heap_threshold`, `gc_time_threshold_ms`, `disabled_alarms`).

In `stacks/projects/billing/dev/config.yaml.example`, replace the jmx comment and the first entry's override:
```yaml
  # valid jmx ids: heap_used, gc_time. heap_max_bytes = JVM -Xmx in bytes,
  # required unless heap_used is disabled (the alarm is a byte threshold);
  # scripts/resolve_heap_max.sh emits it from live telemetry.
  # process_group scopes the queries when a host runs more than one JVM.
  jmx:
    - name: billing-chat-fleet
      app_name:       billing-chat-live
      heap_max_bytes: 12884901888        # -Xmx12G
      process_group:  chat-server-tomcat
      overrides:
        gc_time_threshold_ms: 12000      # 20% of wall clock, for a GC-heavy service
```

In `stacks/projects/billing/dev/terraform.tfvars.example`, make the matching edits: the comment becomes `# valid jmx ids: heap_used, gc_time.` (keeping the `resolve_heap_max.sh` sentence), and the first entry's overrides block becomes:
```hcl
    overrides = {
      gc_time_threshold_ms = 12000 # 20% of wall clock, for a GC-heavy service
    }
```

- [ ] **Step 7: Run the assertion and validate**

Run:
```bash
grep -q 'resource "aws_cloudwatch_metric_alarm" "gc_time"' modules/cloudwatch/metrics-alarm/jmx/main.tf && echo PASS || echo FAIL
grep -c 'ORDER BY' modules/cloudwatch/metrics-alarm/jmx/main.tf
podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/jmx":/w:Z -w /w docker.io/hashicorp/terraform:1.10 validate -no-color
podman run --rm -v "$PWD":/w:Z -w /w docker.io/hashicorp/terraform:1.10 fmt -recursive -check -no-color
```
Expected: `PASS`; a count of at least `2` (one per alarm query, plus comment mentions); `Success! The configuration is valid.`; no fmt output.

- [ ] **Step 8: Optional (work machine) — prove the shape with a throwaway alarm**

This is the check whose absence caused the original failure. No `--alarm-actions`, so it cannot notify anyone:
```bash
aws cloudwatch put-metric-alarm --profile <p> --region <r> \
  --alarm-name TEST-probe-gc-gauge --alarm-description "throwaway probe, delete me" \
  --comparison-operator GreaterThanThreshold --threshold 6000 \
  --evaluation-periods 5 --datapoints-to-alarm 5 --treat-missing-data notBreaching \
  --metrics '[{"Id":"q1","Period":60,"ReturnData":true,"Expression":"SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '"'"'live'"'"' GROUP BY InstanceId ORDER BY SUM() DESC"}]'
aws cloudwatch describe-alarms --alarm-names TEST-probe-gc-gauge \
  --query 'MetricAlarms[0].[StateValue,StateReason]' --output text
aws cloudwatch delete-alarms --alarm-names TEST-probe-gc-gauge
```
Expected: accepted (no `ValidationError`), state `OK` or `INSUFFICIENT_DATA`. If it is rejected, STOP — the delta finding is wrong and Task 2 must be reverted.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -F - <<'EOF'
feat(jmx): reinstate gc_time as a delta gauge query

The agent applies cumulativetodelta to the JMX pipeline, so
jvm_gc_collections_elapsed reaches CloudWatch already as milliseconds of
GC per 60s interval — confirmed over a 3h span, where it rises and
returns to 0 rather than climbing. The alarm therefore needs no metric
math and is expressible as a plain multi-series Insights query with
ORDER BY, which PutMetricAlarm accepts.

This also means the old DIFF(q1) form was wrong twice: rejected by the
API, and differencing an already-differenced series, which measures the
change in GC time rather than GC time. The API error caught a modelling
error.

Threshold stays 6000 ms/min (10% of wall clock) but the window widens to
5 consecutive minutes so a single stop-the-world burst cannot fire it.
Severity is ERROR per the alerting policy: a candidate leading indicator
routed to chat, not the pager, until its lead time is measured.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Lengthen the `heap_used` window and make it overridable

Instantaneous heap sampled every 60s catches a random phase of the collection sawtooth. Sustained-high is the proxy for "the post-GC live set is high", which is the condition worth alarming on.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/jmx/main.tf` (the `heap_used` resource)
- Modify: `modules/cloudwatch/metrics-alarm/jmx/variables.tf` (default threshold, two new window inputs, one new validation)
- Modify: `stacks/projects/billing/dev/variables.tf` (leaf mirror)

**Interfaces:**
- Consumes: Task 2's module.
- Produces: `var.default_heap_threshold` default becomes `90`; new `var.default_heap_evaluation_periods` (number, default `10`); per-entry `overrides.heap_evaluation_periods` (number, optional).

- [ ] **Step 1: Write the failing assertion**

Run:
```bash
grep -A2 'resource "aws_cloudwatch_metric_alarm" "heap_used"' -n modules/cloudwatch/metrics-alarm/jmx/main.tf >/dev/null
grep -q 'heap_evaluation_periods' modules/cloudwatch/metrics-alarm/jmx/variables.tf && echo PASS || echo FAIL
```
Expected now: `FAIL`.

- [ ] **Step 2: Add the inputs**

In `modules/cloudwatch/metrics-alarm/jmx/variables.tf`, add `heap_evaluation_periods = optional(number)` to the `overrides` object (after `heap_threshold`), then change the default threshold variable and add the window variable:

```hcl
variable "default_heap_threshold" {
  description = "Default JVM heap threshold as a percent of each entry's heap_max_bytes. Rendered into a byte threshold on jvm_memory_heap_used. 90 rather than 85 because the alarm now requires a long sustained window: a healthy JVM peaks near -Xmx just before a collection, so only a heap that STAYS high indicates a live set that does not fit."
  type        = number
  default     = 90
}

variable "default_heap_evaluation_periods" {
  description = "Consecutive 60s periods jvm_memory_heap_used must exceed the threshold before the heap alarm fires. Long by design (10 = 10 minutes): duration substitutes for the post-GC sampling CloudWatch cannot do. datapoints_to_alarm is always set equal to this."
  type        = number
  default     = 10
}
```

Add this validation alongside the existing ones in the `resources` variable:
```hcl
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.heap_evaluation_periods, null) == null
      || coalesce(try(r.overrides.heap_evaluation_periods, null), 0) >= 1
    ])
    error_message = "overrides.heap_evaluation_periods must be >= 1, or omitted."
  }
```

- [ ] **Step 3: Use them in the alarm**

In `modules/cloudwatch/metrics-alarm/jmx/main.tf`, in the `heap_used` resource, replace:
```hcl
  evaluation_periods  = 3
  datapoints_to_alarm = 3
```
with:
```hcl
  # Long window on purpose: a healthy JVM touches 90% of -Xmx just before a
  # collection, so a short window fires on the sawtooth. Only a heap that stays
  # high for the whole window indicates a post-GC live set that does not fit —
  # which is also what a GC spiral looks like from the heap side.
  evaluation_periods = coalesce(
    try(each.value.overrides.heap_evaluation_periods, null),
    var.default_heap_evaluation_periods
  )
  datapoints_to_alarm = coalesce(
    try(each.value.overrides.heap_evaluation_periods, null),
    var.default_heap_evaluation_periods
  )
```

- [ ] **Step 4: Mirror in the leaf**

In `stacks/projects/billing/dev/variables.tf`, add `heap_evaluation_periods = optional(number)` to `jmx_resources`' `overrides` object, after `heap_threshold`.

- [ ] **Step 5: Assert and validate**

Run:
```bash
grep -q 'heap_evaluation_periods' modules/cloudwatch/metrics-alarm/jmx/variables.tf && echo PASS || echo FAIL
grep -q 'default     = 90' modules/cloudwatch/metrics-alarm/jmx/variables.tf && echo PASS || echo FAIL
podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/jmx":/w:Z -w /w docker.io/hashicorp/terraform:1.10 validate -no-color
podman run --rm -v "$PWD":/w:Z -w /w docker.io/hashicorp/terraform:1.10 fmt -recursive -check -no-color
```
Expected: `PASS`, `PASS`, `Success! The configuration is valid.`, no fmt output.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -F - <<'EOF'
feat(jmx): long sustained window for heap_used, overridable

jvm_memory_heap_used sampled every 60s catches a random phase of the
collection sawtooth, and a healthy JVM legitimately sits near -Xmx just
before a collection. A 3-minute window therefore fires on normal
behaviour. What distinguishes a sick JVM is that heap STAYS high,
because the post-GC live set is high.

Duration substitutes for the post-GC sampling CloudWatch cannot express:
90% for 10 consecutive minutes, both overridable per entry as EFS
already does for its trend alarm. This is also the heap-side view of the
GC spiral that gc_time watches directly.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 4: Re-enable the ALB `target_response_time` alarm

Latency is the symptom the JVM cascade produces before anything returns 5xx. It is currently commented out, so that failure mode reaches users with no alarm at all. The threshold variable, the per-entry override and its validation all still exist — only the resource and the `disabled_alarms` id are missing.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/alb/main.tf:215-...` (uncomment the block)
- Modify: `modules/cloudwatch/metrics-alarm/alb/variables.tf:79` (`disabled_alarms` valid ids)

**Interfaces:**
- Consumes: existing `var.default_target_response_time_threshold`, `overrides.target_response_time_threshold`, `local.default_severities.target_response_time`.
- Produces: alarm resource label `target_response_time`; output keys `"<alb>:TargetResponseTime"` (the module's outputs already iterate every alarm resource — confirm in Step 4).

- [ ] **Step 1: Write the failing assertion**

Run:
```bash
grep -q '^resource "aws_cloudwatch_metric_alarm" "target_response_time"' modules/cloudwatch/metrics-alarm/alb/main.tf && echo PASS || echo FAIL
```
Expected now: `FAIL`.

- [ ] **Step 2: Uncomment the block**

In `modules/cloudwatch/metrics-alarm/alb/main.tf`, find the block that starts with the commented banner `# # TargetResponseTime Alarm (p90) — disabled per work-machine tuning` and remove the leading `# ` from every line of the banner and the resource, through its closing `# }`. Replace the banner's "disabled per work-machine tuning" line with:

```hcl
#------------------------------------------------------------------------------
# TargetResponseTime Alarm (p90)
#
# Re-enabled 2026-07-31: this is the symptom a JVM GC spiral (or any downstream
# stall) produces BEFORE anything returns 5xx. With it disabled, that failure
# mode reached users with no alarm at all. CRIT per the alerting policy.
#------------------------------------------------------------------------------
```

Do not change the resource body: `extended_statistic = "p90"`, `evaluation_periods = 5`, `datapoints_to_alarm = 5`, `period = 60` are the tuning that was already agreed.

- [ ] **Step 3: Add the alarm id to the validation**

In `modules/cloudwatch/metrics-alarm/alb/variables.tf`, update the `disabled_alarms` validation so `target_response_time` is accepted — both the `contains([...])` list and the error message:
```hcl
        for m in try(r.overrides.disabled_alarms, []) : contains(["elb_5xx", "target_5xx", "unhealthy_host", "target_response_time"], m)
```
```hcl
    error_message = "overrides.disabled_alarms entries must be a subset of: elb_5xx, target_5xx, unhealthy_host, target_response_time"
```

- [ ] **Step 4: Add it to the outputs**

`modules/cloudwatch/metrics-alarm/alb/outputs.tf` enumerates each alarm resource explicitly, so a new alarm is invisible to remote-state consumers until it is listed. Add a fourth line to **both** merges:

```hcl
output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.elb_5xx : "${k}:HTTPCode_ELB_5XX_Count" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.target_5xx : "${k}:HTTPCode_Target_5XX_Count" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.unhealthy_host : "${k}:UnHealthyHostCount" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.target_response_time : "${k}:TargetResponseTime" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.elb_5xx : "${k}:HTTPCode_ELB_5XX_Count" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.target_5xx : "${k}:HTTPCode_Target_5XX_Count" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.unhealthy_host : "${k}:UnHealthyHostCount" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.target_response_time : "${k}:TargetResponseTime" => v.alarm_name }
  )
}
```

Note the key differs from the others: `unhealthy_host` is keyed `"<alb>:<tg>"` because it fans out per target group, while this alarm is per ALB like `elb_5xx`.

- [ ] **Step 5: Assert and validate**

Run:
```bash
grep -q '^resource "aws_cloudwatch_metric_alarm" "target_response_time"' modules/cloudwatch/metrics-alarm/alb/main.tf && echo PASS || echo FAIL
podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/alb":/w:Z -w /w docker.io/hashicorp/terraform:1.10 init -backend=false -no-color >/dev/null
podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/alb":/w:Z -w /w docker.io/hashicorp/terraform:1.10 validate -no-color
podman run --rm -v "$PWD":/w:Z -w /w docker.io/hashicorp/terraform:1.10 fmt -recursive -check -no-color
```
Expected: `PASS`, `Success! The configuration is valid.`, no fmt output.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -F - <<'EOF'
feat(alb): re-enable the p90 TargetResponseTime alarm

Latency is the symptom a downstream stall produces before anything
returns 5xx — the EFS-throttle cascade degraded response times for
roughly 25 minutes while 5xx stayed flat. With this alarm commented out,
that failure mode reached users with nothing firing.

The threshold variable, the per-entry override and its validation were
all still in place; only the resource and the disabled_alarms id were
missing. Tuning is unchanged from when it was disabled (p90, 5 of 5
periods at 60s).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 5: Reclassify severities

Every change here is one string in a module's `local.default_severities`. Severity flows into `alarm_actions`, `ok_actions` and the `[SEVERITY]-` description prefix — all in-place updates, no resource replacement, no `alarm_name` change.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/alb/main.tf` (severity map)
- Modify: `modules/cloudwatch/metrics-alarm/asg/main.tf` (severity map)
- Modify: `modules/cloudwatch/metrics-alarm/rds/main.tf` (severity map)
- Modify: `modules/cloudwatch/metrics-alarm/s3/main.tf` (severity map)
- Modify: `modules/cloudwatch/metrics-alarm/opensearch/main.tf` (severity map)

**Interfaces:**
- Consumes: Tasks 2–4 (jmx severities were set in Task 2; alb `target_response_time` must exist before it can be classified).
- Produces: the tier distribution the spec specifies — 9 CRIT / 14 ERROR / 19 WARN.

- [ ] **Step 1: Write the failing assertion**

Run:
```bash
grep -c 'CRIT' modules/cloudwatch/metrics-alarm/alb/main.tf modules/cloudwatch/metrics-alarm/asg/main.tf
```
Expected now: `0` for both.

- [ ] **Step 2: alb — all four to CRIT**

```hcl
  default_severities = {
    elb_5xx              = "CRIT"
    target_5xx           = "CRIT"
    unhealthy_host       = "CRIT"
    target_response_time = "CRIT"
  }
```

- [ ] **Step 3: asg — capacity to CRIT**

Both the legacy and fleet capacity alarms read `local.default_severities.in_service_capacity`, so this one edit promotes both:
```hcl
  default_severities = {
    in_service_capacity = "CRIT"
    cpu                 = "WARN"
    memory              = "WARN"
    disk                = "WARN"
  }
```

- [ ] **Step 4: rds — three to ERROR**

```hcl
  default_severities = {
    freeable_memory      = "ERROR"
    cpu                  = "WARN"
    database_connections = "WARN"
    free_storage         = "ERROR"
    volume_bytes_used    = "WARN"
    engine_uptime        = "CRIT"
    read_latency         = "WARN"
    write_latency        = "ERROR"
    acu_utilization      = "WARN"
    serverless_capacity  = "WARN"
  }
```

- [ ] **Step 5: s3 and opensearch**

s3:
```hcl
  default_severities = {
    error_5xx          = "WARN"
    replication_failed = "ERROR"
  }
```
opensearch (`free_storage` joins the other three):
```hcl
  default_severities = {
    cpu                = "ERROR"
    jvm_memory         = "ERROR"
    old_gen_jvm_memory = "ERROR"
    free_storage       = "ERROR"
  }
```

- [ ] **Step 6: Assert the whole distribution**

Run this from the repo root; it recounts every module's severity map and prints the totals:
```bash
python3 - <<'PY'
import re, glob
tally = {"CRIT": [], "ERROR": [], "WARN": []}
for f in sorted(glob.glob("modules/cloudwatch/metrics-alarm/*/main.tf")):
    mod = f.split("/")[-2]
    src = open(f).read()
    sev = dict(re.findall(r"(\w+)\s*=\s*\"(CRIT|ERROR|WARN)\"",
                          re.search(r"default_severities = \{(.*?)\n  \}", src, re.S).group(1)))
    # One severity key can back several alarm resources: the asg module's fleet_*
    # alarms reuse the legacy keys. Count RESOURCES, not keys, or the three fleet
    # alarms vanish from the tally.
    for label in re.findall(r'^resource "aws_cloudwatch_metric_alarm" "(\w+)"', src, re.M):
        key = label[len("fleet_"):] if label.startswith("fleet_") else label
        if key not in sev:
            print(f"  !! {mod}.{label}: no severity key '{key}'")
            continue
        tally[sev[key]].append(f"{mod}.{label}")
for s in ("CRIT", "ERROR", "WARN"):
    print(f"{s:5} {len(tally[s]):3}  {', '.join(sorted(tally[s]))}")
print(f"total {sum(len(v) for v in tally.values())}")
PY
```
Expected exactly:
```
CRIT    9  alb.elb_5xx, alb.target_5xx, alb.target_response_time, alb.unhealthy_host, asg.fleet_in_service_capacity, asg.in_service_capacity, ec2.status_check, ec2.status_check_ebs, rds.engine_uptime
ERROR  14  cloudfront.error_5xx, elasticache.cpu, elasticache.memory, jmx.gc_time, jmx.heap_used, lambda.errors, opensearch.cpu, opensearch.free_storage, opensearch.jvm_memory, opensearch.old_gen_jvm_memory, rds.free_storage, rds.freeable_memory, rds.write_latency, s3.replication_failed
WARN   19  apigateway.error_5xx, asg.fleet_cpu, asg.fleet_disk, asg.fleet_memory, cloudfront.origin_latency, ec2.cpu, ec2.disk, ec2.memory, efs.throughput_util, lambda.concurrency, lambda.duration, lambda.throttles, rds.acu_utilization, rds.cpu, rds.database_connections, rds.read_latency, rds.serverless_capacity, s3.error_5xx, ses.bounce_rate
total 42
```
Any `!!` line means a resource whose severity key is missing — fix that before committing. Before this task the same script prints `3 / 10 / 27, total 40`.

- [ ] **Step 7: Validate every touched module**

```bash
for m in alb asg rds s3 opensearch; do
  podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/$m":/w:Z -w /w \
    docker.io/hashicorp/terraform:1.10 init -backend=false -no-color >/dev/null
  printf "%-11s " "$m"
  podman run --rm -v "$PWD/modules/cloudwatch/metrics-alarm/$m":/w:Z -w /w \
    docker.io/hashicorp/terraform:1.10 validate -no-color | tail -1
done
podman run --rm -v "$PWD":/w:Z -w /w docker.io/hashicorp/terraform:1.10 fmt -recursive -check -no-color
```
Expected: `Success! The configuration is valid.` five times, no fmt output.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -F - <<'EOF'
feat(alarms): reclassify severities against what the tiers do

CRIT pages, ERROR is chat, WARN is a digest. Measured against that
contract the old distribution was inverted: an EC2 status check paged,
while target_5xx (users receiving errors) was WARN and unhealthy_host
(every target down) was ERROR. A total outage at 02:00 paged nobody.

CRIT now holds only symptoms and liveness: alb elb_5xx / target_5xx /
unhealthy_host / target_response_time, asg capacity (both modes), plus
the existing ec2 status checks and rds engine_uptime.

Promoted to ERROR: rds free_storage / freeable_memory / write_latency,
s3 replication_failed (durability), opensearch free_storage so the four
opensearch alarms move together.

Distribution goes from 3/6/31 to 9/14/19. Nothing is deleted, and
severity is an in-place update — no alarm is replaced.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 6: Update the living docs

**Files:**
- Modify: `CLAUDE.md` (Severity → SNS Routing section; JMX bullet)
- Modify: `cwagent/ec2-java/README.md` (contract section)

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces: no code interfaces; documentation only.

- [ ] **Step 1: Write the failing assertion**

Run:
```bash
grep -q 'metrics_collection_interval' cwagent/ec2-java/README.md && echo PASS || echo FAIL
```
Expected now: `FAIL` (the README documents the 60s interval but not what depends on it).

- [ ] **Step 2: Extend the severity section in CLAUDE.md**

In `CLAUDE.md`, under `### Severity → SNS Routing`, append after the existing paragraph:

```markdown
The tiers are a **routing contract, not labels**: CRIT reaches a pager and wakes someone at any hour, ERROR reaches chat and is handled in working hours, WARN is a digest read deliberately. Classification follows from that — CRIT holds only user-visible symptoms and liveness (alb `elb_5xx`/`target_5xx`/`unhealthy_host`/`target_response_time`, asg capacity, ec2 status checks, rds `engine_uptime`), causes sit at ERROR until their lead time is measured, and saturation trends sit at WARN. See `docs/superpowers/specs/2026-07-31-alerting-policy-design.md` for the full classification and the promotion criterion a signal must meet to reach CRIT.

`apigateway error_5xx` stays WARN deliberately: the customer-facing path is covered by a synthetic canary alarm that lives outside this repo. Do not "fix" it without checking that canary still exists.
```

- [ ] **Step 3: Update the JMX bullet in CLAUDE.md**

In the `- **JMX**:` bullet, replace the sentence beginning `**`gc_time` was removed 2026-07-31**` with:

```markdown
`gc_time` = `SELECT SUM(jvm_gc_collections_elapsed) … GROUP BY InstanceId ORDER BY SUM() DESC`, thresholded in **ms of GC per minute** (default 6000 = 10% of wall clock) over 5 consecutive minutes. It needs no metric math: the agent's `cumulativetodelta/jmx` processor converts the counter before publishing, so the metric arrives as a per-interval delta — which also means the threshold's meaning is tied to `metrics_collection_interval: 60`. An earlier `DIFF(q1)` form was wrong twice (rejected by `PutMetricAlarm`, and differencing an already-differenced series).
```

Also change the bullet's opening from `Heap alarm for Java apps` back to `Heap and GC alarms for Java apps`, and update the sentence about `heap_used` to state the long window: `90% of heap_max_bytes for 10 consecutive minutes (overridable via overrides.heap_evaluation_periods)`.

- [ ] **Step 4: Add the interval-coupling note to the agent README**

In `cwagent/ec2-java/README.md`, in the `## Contract (floor, not ceiling)` list, after the bullet beginning `- Namespace `CWAgent`; 60s collection interval.`, add:

```markdown
- **The 60s interval is load-bearing, not a preference.** The agent applies a
  `cumulativetodelta` processor to the `jmx` pipeline, so `jvm_gc_collections_elapsed`
  is published as a delta *per collection interval*. The JMX module's `gc_time` alarm
  thresholds it as "ms of GC per minute" (6000 = 10% of wall clock). Halve the interval
  and every GC threshold silently halves in meaning, with no error anywhere. Changing
  `metrics_collection_interval` means revisiting `default_gc_time_threshold_ms`.
```

- [ ] **Step 5: Assert**

Run:
```bash
grep -q 'metrics_collection_interval' cwagent/ec2-java/README.md && echo PASS || echo FAIL
grep -q 'routing contract, not labels' CLAUDE.md && echo PASS || echo FAIL
grep -q 'ORDER BY SUM() DESC' CLAUDE.md && echo PASS || echo FAIL
```
Expected: `PASS` three times.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -F - <<'EOF'
docs: record the routing contract and the GC interval coupling

CLAUDE.md gains the severity tiers as a contract (CRIT pages, ERROR is
chat, WARN is a digest) with the classification that follows from it,
and the note that apigateway error_5xx stays WARN because a synthetic
canary outside this repo covers the customer-facing path.

The JMX bullet documents gc_time in its reinstated form, and
cwagent/ec2-java/README.md records that the 60s collection interval is
load-bearing: the GC threshold is expressed in ms per minute and the
metric is a per-interval delta, so changing the interval silently
changes what the alarm means.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 7: Restore preflight fidelity

`check_jmx_metrics.sh` and `check_asg_fleet_metrics.sh` claim to run the alarms' own SELECTs. Since Task 1 they no longer do — their copies lack `ORDER BY`. Note this is cosmetic for detection (`GetMetricData` accepts what `PutMetricAlarm` refuses, so no preflight could have caught the original failure) but the claim must be true or the scripts mislead.

**Files:**
- Modify: `scripts/check_jmx_metrics.sh` (both query strings)
- Modify: `scripts/check_asg_fleet_metrics.sh` (the three `GROUP BY` query strings)

**Interfaces:**
- Consumes: the final query strings from Tasks 1–3.
- Produces: no interfaces; script behaviour is unchanged apart from the query text.

- [ ] **Step 1: Write the failing assertion**

Run:
```bash
grep -c 'ORDER BY' scripts/check_jmx_metrics.sh scripts/check_asg_fleet_metrics.sh
```
Expected now: `0` for both.

- [ ] **Step 2: Update the jmx script's queries**

In `scripts/check_jmx_metrics.sh`, append `ORDER BY AVG() DESC` to the `jvm_memory_heap_used` query and `ORDER BY SUM() DESC` to the `jvm_gc_collections_elapsed` query, so each matches its alarm exactly:
```bash
      "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId ORDER BY AVG() DESC" \
```
```bash
      "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId ORDER BY SUM() DESC" \
```
Leave the `jvm_memory_heap_max` reconciliation query alone — it has no `GROUP BY` and backs no alarm.

- [ ] **Step 3: Update the asg fleet script's queries**

In `scripts/check_asg_fleet_metrics.sh`, append `ORDER BY AVG() DESC` to each of the three `GROUP BY InstanceId` queries (`CPUUtilization`, `mem_used_percent`, `disk_used_percent`). Leave the capacity query (`SUM`, no `GROUP BY`) unchanged.

- [ ] **Step 4: Assert and syntax-check**

```bash
grep -c 'ORDER BY' scripts/check_jmx_metrics.sh scripts/check_asg_fleet_metrics.sh
bash -n scripts/check_jmx_metrics.sh && bash -n scripts/check_asg_fleet_metrics.sh && echo "syntax OK"
```
Expected: `2` for the jmx script, `3` for the asg script, then `syntax OK`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -F - <<'EOF'
fix(preflight): mirror the alarms' ORDER BY in the check scripts

Both Insights-based checks advertise that they run the alarms' own
SELECTs. Since the alarms gained the mandatory ORDER BY clause, their
copies no longer matched.

This is fidelity, not detection: GetMetricData accepts multi-series
queries that PutMetricAlarm rejects, so no preflight run could have
caught the original apply failure. The scripts still have to say what
they do.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

## Deliberately unchanged (do not "fix" these)

- **EFS.** The spec demotes it in *interpretation*, not in code: `throughput_util` keeps its
  existing 6h window and WARN severity. No module edit. Its comment already explains the
  long window; what changes is that the spec now records it as a cost-and-capacity signal
  that could not have caught the incident, rather than protection against a repeat.
- **apigateway `error_5xx`** stays WARN — a synthetic canary outside this repo covers the
  customer-facing path.
- **cloudfront `error_5xx`** stays ERROR, its current value; it was never discussed.
- **`dashboards/jmx-jvm.json`** and `modules/cloudwatch/dashboard/jmx/` are untouched.
  Dashboard widgets go through `GetMetricData`, which has no single-series constraint, so
  their `GROUP BY` queries need no `ORDER BY`.

## Deferred to the work machine (not tasks)

- **Apply.** These changes alter live alarm routing. The capacity watchdogs and `elb_5xx` are the promotions most likely to surprise: confirm the watchdog stays quiet through a CodeDeploy blue/green before letting it page.
- **The reproduction experiment** (spec: "Promotion criterion"). Until it runs, `gc_time` and `heap_used` stay at ERROR.
- **The PromQL question** (spec: "Open questions"). Query Studio → PromQL tab → `{"jvm_threads_count"}`, with an AWS-vended metric as positive control.
- **`thread_count`** is deliberately not implemented. Revive only with measured lead time, and remember a bounded pool plateaus rather than climbing.
