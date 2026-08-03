# Module Identity Boundaries — EC2 / ASG-fleet / JMX — Design

**Date:** 2026-07-30
**Status:** Approved pending the blocking verify item below
**Builds on:** `feat/asg-fleet-alarms` (`docs/superpowers/specs/2026-07-24-asg-fleet-alarms-design.md`),
which introduced fleet mode in the ASG module. This spec corrects the module
boundary that work left behind.
**Targets:**
- `modules/cloudwatch/metrics-alarm/jmx/` — re-identify on `AppName`; drop instance lookup
- `modules/cloudwatch/metrics-alarm/asg/` — shed `heap_used` to the JMX module
- `modules/cloudwatch/dashboard/jmx/` — query-based widgets (loses its `instance_ids` input)
- `cwagent/ec2-java/`, `cwagent/jmx/` — snake_case JVM metric names
- `scripts/check_jmx_metrics.sh`, `scripts/check_asg_fleet_metrics.sh`
- `stacks/projects/billing/dev/` — `variables.tf`, `main.tf`, and both example configs
- `dashboards/jmx-jvm.json`, `CLAUDE.md`

## Problem

The JMX module resolves EC2 instance IDs from the Name tag at plan time
(`data.aws_instances` + a `check {}` + per-alarm `precondition`s requiring
exactly one match). ASG fleet instances share one Name tag, so every fleet host
fails that precondition and the plan aborts.

Making the Name tag unique per fleet instance would not fix it. The module pins
`dimensions = { InstanceId = ... }` at apply time, and CodeDeploy blue/green
replaces those instances on every deploy — the alarm would then watch dead
instance IDs and, being `notBreaching`, sit green forever. The precondition
failure is the guardrail working, not the defect.

Meanwhile the 2026-07-24 work gave the ASG module a `heap_used` fleet alarm,
duplicating the JMX module's heap alarm. That happened because fleet mode needed
a different *identity* mechanism, so it re-implemented the *measurement*
alongside it. Left alone, every future JVM alarm has to be written twice.

## Situation and constraints

- EC2 instances are either standalone or members of an ASG fleet.
- Name tags are near-unique for standalone hosts and routinely duplicated within
  a fleet.
- Every monitored instance can carry an identity tag (launch template /
  instance tagging is under our control). Standalone hosts **may share** a group
  tag value; their Name tags are the per-host discriminator.
- Any host exposing JVM metrics necessarily runs the CloudWatch Agent, and the
  agent config appends `AppName` — so for JMX, `AppName` is guaranteed by
  construction.

## Identity model

Two identity mechanisms, each owning the cases it fits:

- **Name-tag lookup** (`data.aws_instance*` → pinned `InstanceId` dimensions).
  Correct for standalone hosts: names are unique, instances are long-lived, and
  per-host granularity and thresholds are preserved.
- **Tag/dimension-scoped Metrics Insights** (`WHERE … GROUP BY InstanceId`).
  Correct wherever membership churns, and the only option where Name tags are
  duplicated.

Key values:

- `app_tag_key` — module variable, default `AppName`. The **EC2/ASG resource tag
  key** used by native-metric queries (`WHERE tag.<key> = 'v'`). Configurable.
- `AppName` — the **CWAgent dimension**, fixed by the agent config, not
  configurable from Terraform. Modules reading only CWAgent metrics (JMX) never
  touch `app_tag_key`.

## Where the resource tag is used, and where it is not

Two identity carriers are easy to conflate. They are independent and must be
kept in sync by hand.

| Alarm | Source | Filter | Requires the resource tag on |
|---|---|---|---|
| `asg` `in_service_capacity` | `AWS/AutoScaling` | `WHERE tag.<app_tag_key>` | **the ASG resource itself** |
| `asg` `cpu` | `AWS/EC2` | `WHERE tag.<app_tag_key>` | **each EC2 instance** |
| `asg` `memory`, `disk` | `CWAgent` | `WHERE AppName` (dimension) | nothing |
| `jmx` `heap_used`, `gc_time` | `CWAgent` | `WHERE AppName` (dimension) | nothing |
| `ec2` (all five) | `AWS/EC2` + `CWAgent` | pinned `dimensions` from a `tag:Name` lookup | nothing — `Name` only |

So `app_tag_key` is consumed by exactly **two queries**, both in the ASG module,
both against native AWS namespaces. Every CWAgent-sourced alarm — including all
of `jmx` — ignores resource tags entirely and matches on the `AppName`
*dimension* that the agent config appends.

**Mechanism.** The `tag.<Key>` filter works only because of CloudWatch's
account-level "resource tags on telemetry" setting, which joins AWS resource
tags onto metrics from supported namespaces so Metrics Insights can filter on
them. It is per account **and** per region; each env here is its own account, so
it must be enabled in each.

**The agent dimension is not the tag.** `append_dimensions` can resolve only a
fixed set of placeholders (`${aws:InstanceId}`, `${aws:AutoScalingGroupName}`,
`${aws:ImageId}`, `${aws:InstanceType}`) — there is no mechanism to read an
arbitrary tag. The `AppName` dimension value is a literal string substituted into
the Parameter Store copy of the config. Three values must therefore agree:

1. the `AppName` resource tag on the ASG and its instances (ASG native queries),
2. `"AppName": "<v>"` in the agent config (all CWAgent queries),
3. `app_name` in the stack config (what Terraform renders into both).

Drift between them fails silently in the green direction for every alarm except
capacity, which is why the preflight scripts exercise both paths — a tag-scoped
native query *and* a dimension-scoped CWAgent query — rather than checking
either alone.

**Tag propagation requirements.** Instances need the tag via the launch template
(or `propagate_at_launch`); the ASG resource needs it in its own tag set. Under
CodeDeploy blue/green a *new* ASG is created per deployment, so the capacity
alarm's correctness depends on the tag landing on the successor ASG. Two risks
follow, both to confirm on the work machine:

- If CodeDeploy does not copy ASG tags to the replacement ASG, the capacity
  query matches nothing and — being `missing = breaching` — pages.
- Even when tags are copied, telemetry tag joining is not instantaneous. A gap
  between the new ASG appearing and its tags being queryable is a window where
  the capacity alarm sees no data. Its evaluation window is 10 × 60s, so the gap
  must stay under ~10 minutes to avoid a spurious page.

## Module boundaries

| Module | Target class | Identity | Alarms |
|---|---|---|---|
| `ec2` | standalone hosts | `name` → Name-tag lookup → pinned `InstanceId` | status_check, status_check_ebs, cpu, memory, disk |
| `asg` | fleets | `app_name` (fleet) / `name` (legacy, stable ASG names) | in_service_capacity, cpu, memory, disk |
| `jmx` | Java, anywhere | `app_name` only | heap_used, gc_time |

Compositions: `ec2` · `ec2 + jmx` · `asg` · `asg + jmx`.

An `app_name` mode for the `ec2` module is **deliberately not built** (YAGNI).
Nothing here blocks adding it later; the ASG module already covers per-instance
CPU/memory/disk for fleets.

The `asg` module keeping cpu/memory/disk while `ec2` also has them is accepted
duplication: the two are at different identity scopes, and collapsing them would
mean every module carrying dual modes. The cost is that a new OS-level alarm is
written twice. This is the deliberate trade for a simple composition story.

## Module interfaces

### `asg` — remove heap

Delete `heap_max_bytes`, `process_group`, `overrides.heap_threshold_pct`, the
`fleet_heap_used` resource, and its output-map entry. Fleet alarm IDs become
`{in_service_capacity, cpu, memory, disk}`; the `disabled_alarms` validation and
the "fleet-only fields" validation shrink accordingly. Legacy entries are
untouched.

No AWS impact: the fleet heap alarm was never applied.

### `jmx` — re-identify on `AppName`

```hcl
variable "resources" {
  type = list(object({
    name           = string           # label only: alarm naming + output keys
    app_name       = string           # REQUIRED — CWAgent AppName dimension value
    heap_max_bytes = optional(number) # JVM -Xmx in bytes; required unless heap_used disabled
    process_group  = optional(string) # optional ProcessGroupName scope (multi-JVM hosts)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity             = optional(string)
      description          = optional(string)
      heap_threshold       = optional(number)  # percent of heap_max_bytes
      gc_time_threshold_ms = optional(number)
      disabled_alarms      = optional(set(string), [])  # {heap_used, gc_time}
    }), {})
  }))
}
```

Deleted: `data.aws_instances.by_name`, the `check "jmx_name_tag_uniqueness"`
block, both `lifecycle.precondition` blocks, `local.instance_ids`, and the
`instance_ids` output.

Validations to add, mirroring the ASG module's: `app_name` non-empty after
`trimspace`, `process_group` non-empty when set, `app_name` unique across
entries, `heap_max_bytes > 0` required unless `heap_used` is disabled,
`heap_threshold` within 0–100, `disabled_alarms ⊆ {heap_used, gc_time}`.

Note the Terraform idiom, learned on the previous branch: `x == null ||
trimspace(x) != ""` does **not** work — `||` does not short-circuit and
`trimspace(null)` errors. Use `try(trimspace(x), "-") != ""`.

`heap_threshold` keeps its name and its user-facing meaning ("alarm above X% of
max"). Only the computation changes, from live metric math to a static byte
threshold.

### `ec2` — unchanged

No changes. It remains the standalone, Name-tag, instance-pinned module.

## Alarm definitions (`jmx`)

Both alarms: `period = 60` (CWAgent publishes at 60s; unchanged from today),
`evaluation_periods = 3`, `datapoints_to_alarm = 3`,
`treat_missing_data = "notBreaching"`, default severity WARN, SNS routing and
tags per the repo convention.

**`heap_used`** — `{Project}-{Env}-JMX-[{name}]-HeapUsedBytes`

```
q1 (return_data = true):
  SELECT AVG(jvm_memory_heap_used) FROM "CWAgent"
  WHERE AppName = '<app_name>' [AND ProcessGroupName = '<process_group>']
  GROUP BY InstanceId

threshold           = floor(heap_threshold × heap_max_bytes / 100)
comparison_operator = GreaterThanThreshold
```

A byte threshold, not the current `100*used/max` ratio: CloudWatch math cannot
divide two `GROUP BY` series arrays elementwise. For a homogeneous fleet with a
known `-Xmx` the two are equivalent. The alarm is renamed to `HeapUsedBytes`
because it now measures bytes; `alarm_name` is ForceNew, so deployed alarms are
destroyed and recreated, and the output key changes to `"<name>:HeapUsedBytes"`.

**`gc_time`** — `{Project}-{Env}-JMX-[{name}]-GcTimeMsPerMinute` (name unchanged)

```
q1 (return_data = false):
  SELECT SUM(jvm_gc_collections_elapsed) FROM "CWAgent"
  WHERE AppName = '<app_name>' [AND ProcessGroupName = '<process_group>']
  GROUP BY InstanceId
e1 (return_data = true):
  DIFF(q1)

threshold = gc_time_threshold_ms (default 6000)
```

`SELECT SUM` corresponds to the current `stat = "Sum"`: it totals time-in-GC
across the per-collector (`name` dimension) series within each instance. `DIFF`
yields the delta from the previous datapoint, so at `period = 60` the unit is
ms of GC per minute — identical to today's threshold semantics.

`DIFF` over `RATE` was chosen because `DIFF` is empirically verified for
multi-series results (below) and preserves the existing threshold unit. `RATE`
would be period-independent, but period is pinned at 60, so that advantage is
inert.

Two inherited properties of `DIFF`, both documented rather than fixed:

- The first datapoint of a series has no predecessor and produces no value.
- A JVM restart resets the counter, making `DIFF` negative, so the alarm cannot
  fire across a restart. This fails safe (misses, never false-fires).

**Missing-data coherence.** All four JMX/fleet per-instance alarms are
`notBreaching` because series legitimately vanish during deploys. "The host is
gone" is covered elsewhere and without a gap: the `ec2` module's `status_check`
(missing = breaching) for standalone hosts, the `asg` module's capacity
watchdog (missing = breaching) for fleets.

## Metric naming contract — snake_case

JVM metric names are renamed at the agent, from OTel dotted names to snake_case:

| Old | New |
|---|---|
| `jvm.memory.heap.used` | `jvm_memory_heap_used` |
| `jvm.memory.heap.max` | `jvm_memory_heap_max` |
| `jvm.memory.heap.committed` | `jvm_memory_heap_committed` |
| `jvm.memory.nonheap.*` | `jvm_memory_nonheap_*` |
| `jvm.gc.collections.count` | `jvm_gc_collections_count` |
| `jvm.gc.collections.elapsed` | `jvm_gc_collections_elapsed` |
| `jvm.threads.count` | `jvm_threads_count` |
| `jvm.classes.loaded` | `jvm_classes_loaded` |

Rationale: dots are not valid in PromQL metric names, so dotted metrics are
structurally unaddressable from CloudWatch's PromQL dialect; and in SQL they
require double-quoting everywhere, which is a persistent trap across shell, JSON
and console layers. snake_case also matches every other CWAgent metric
(`mem_used_percent`, `disk_used_percent`, `cpu_usage_idle`).

The rename is done in the agent config's `measurement` array, which accepts
objects as well as strings:

```json
"measurement": [
  { "name": "jvm.memory.heap.used",       "rename": "jvm_memory_heap_used" },
  { "name": "jvm.gc.collections.elapsed", "rename": "jvm_gc_collections_elapsed" }
]
```

Consequences, all in scope:

- Renamed metrics are **new series**. Historical data stays under the old names
  and is not carried over; alarms start evaluating from scratch.
- Every consumer updates in the same change: the `jmx` module, the ASG module's
  fleet heap query (removed here anyway), both cwagent templates and their
  README contracts, `modules/cloudwatch/dashboard/jmx/`,
  `dashboards/jmx-jvm.json`, and both preflight scripts.

## CWAgent config changes

`cwagent/ec2-java/` and `cwagent/jmx/`:

1. JVM measurements switch to the `{name, rename}` object form above.
2. `cwagent/ec2-java/` keeps `aggregation_dimensions: [["InstanceId"],
   ["InstanceId","path"]]`. Note the `[InstanceId]` rollup's purpose narrows:
   it no longer serves the JMX module (now query-scoped, reading full-dimension
   series), and remains only for the `ec2` module's classic `memory` alarm.
3. `cwagent/jmx/` is documented as **superseded** by `cwagent/ec2-java/`. It
   appends only `InstanceId` and no `AppName`, so hosts on it cannot be
   monitored by the re-identified JMX module.

Queries use plain `FROM "CWAgent"`, never `SCHEMA()`, for CWAgent-sourced
metrics — see the verified findings below.

## Dashboard consequence

`modules/cloudwatch/dashboard/jmx/` currently consumes the JMX module's
`instance_ids` output, which this design deletes. The dashboard moves to
Metrics Insights query widgets scoped by `AppName` and grouped by `InstanceId`,
so widget content resolves at render time and follows fleet membership without
a Terraform run — the same property the alarms gain. Its input becomes
`app_name` (plus the optional `process_group`) instead of a map of instance IDs.
`dashboards/jmx-jvm.json` is regenerated to match.

## Stack wiring and documentation

- `stacks/projects/billing/dev/variables.tf`: `jmx_resources` gains `app_name`,
  `heap_max_bytes`, `process_group`; `asg_resources` loses `heap_max_bytes`,
  `process_group`, and `overrides.heap_threshold_pct`.
- `stacks/projects/billing/dev/main.tf:156` currently passes
  `module.jmx_alarms[0].instance_ids` into the dashboard module. That output is
  deleted here, so the call site changes to pass `app_name` (and
  `process_group`) instead. **This line breaks the plan if missed** — it is not
  a `try()`-wrapped optional.
- `terraform.tfvars.example` and `config.yaml.example`: rework the `jmx` and
  `asg` entries to the new shapes, including a worked fleet composition
  (`asg` + `jmx` sharing one `app_name`).
- `CLAUDE.md`: rewrite the JMX bullet (identity, byte threshold, no Name-tag
  lookup), amend the ASG bullet (heap removed), update the Dashboards and
  Preflight Checks sections, and record the snake_case metric contract.

## Migration and rollout order

Per host group, in this order. Getting it wrong produces silently green alarms,
which is the failure class the preflight exists to catch.

1. Parameter Store config updated from `cwagent/ec2-java/`: `AppName` present on
   every plugin, JVM metrics renamed. Agent restarted.
2. Verify metrics are flowing under the new names with the expected dimensions
   (`scripts/check_jmx_metrics.sh`, rewritten below).
3. Apply the Terraform change: ASG entries drop the heap fields, JMX entries
   gain `app_name` and `heap_max_bytes`.

Notes:

- Old-name series stop being written at step 1. Alarms on old names go
  `INSUFFICIENT_DATA` until step 3 replaces them.
- Renaming `HeapUsedPercent` → `HeapUsedBytes` destroys and recreates the alarm.
- ASG fleet entries move `heap_max_bytes` / `process_group` /
  `heap_threshold_pct` into the corresponding `jmx` entry.

## Preflight changes

`scripts/check_jmx_metrics.sh` is rewritten from `InstanceId`-based
`list-metrics` calls to the same Metrics Insights `SELECT`s the alarms run, via
`get-metric-data` — matching the pattern established by
`check_asg_fleet_metrics.sh`. Per JMX entry it verifies:

1. the heap query returns data for `AppName = <v>` (and `ProcessGroupName` when
   the entry sets `process_group`),
2. `jvm_gc_collections_elapsed` returns data,
3. the latest `jvm_memory_heap_max` is within ±10% of `heap_max_bytes`.

`scripts/check_asg_fleet_metrics.sh` loses its heap checks (both the series
check and the `heap_max_bytes` reconciliation) — that responsibility moves with
the alarm. It also stops hardcoding `AppName` for native-metric queries and
reads `app_tag_key`, closing the residual noted at the end of the previous
branch.

Both scripts use `list-metrics --recently-active PT3H` as a first-line diagnostic
**on the no-data path**: that flag's window is the same one Metrics Insights can
see, so a metric absent from it is not queryable regardless of syntax. It is what
separates "the metric does not exist" (agent config not deployed, name not
renamed) from "the metric exists but the `WHERE` filter matched nothing" — the
most common confusion during the rename rollout. It needs
`cloudwatch:ListMetrics` on the preflight role in addition to
`cloudwatch:GetMetricData`; if the call fails the scripts say so rather than
inferring anything from it.

Both scripts read each `GROUP BY InstanceId` result set as a set, not as
`MetricDataResults[0]`: results come back in no guaranteed order and Metrics
Insights matches any series with data in ~3h — wider than the scripts' 1h window —
so an instance terminated shortly before the run returns with an empty `Values`
array and must not be mistaken for "the query returned nothing". They report the
first result that has a datapoint, plus the number of series returned so it can be
compared against `desired_capacity`.

Both scripts fail (exit 1) when the tfvars parser matched a `<var>_resources = [`
but extracted no entries from it. Exiting 0 having run zero checks is reserved for
a genuinely absent variable or a literal empty list. Line comments are stripped
before the parsers' brace/bracket counting, so neither a commented-out entry nor an
unbalanced brace inside a comment can change what is considered live.

## Verified during design

Established empirically against a live account while writing this spec. Recorded
so they are not re-litigated:

- **Plain `FROM "CWAgent"` tolerates extra dimensions.** A query filtering on
  `AppName` and grouping by `InstanceId` matches series that also carry
  `ProcessGroupName` and the per-collector `name`. `SCHEMA()` requires the exact
  dimension set and does not. The 2026-07-24 spec's assumption holds, so the
  shipped `fleet_memory` / `fleet_disk` queries are structurally sound.
- **`DIFF()` works over a multi-series `GROUP BY` result**, returning one series
  per instance rather than collapsing to one. This is what makes a fleet
  `gc_time` alarm possible.
- **The agent's `rename` field works for the `jmx` section**, not just the
  standard plugins.
- **Metrics Insights only sees metrics with data in roughly the last 3 hours.**
  A freshly renamed metric appears in `list-metrics` immediately but returns
  empty `Values` until enough datapoints accumulate — the confusing signature is
  `MetricDataResults` present, `Values` empty.
- **Metric math cannot be nested inside a Metrics Insights query.**
  `DIFF(SELECT …)` is a syntax error; the SQL must be its own query entry
  referenced by ID from a separate math expression.

## Blocking verify items

**1. Resource-tag telemetry must cover both native namespaces.** Confirm
`WHERE tag.<app_tag_key>` returns data for `AWS/EC2` (the `cpu` alarm) *and*
`AWS/AutoScaling` (the `capacity` alarm) in each account/region. The second was
already unconfirmed in the 2026-07-24 spec. Also confirm the tag survives a
CodeDeploy blue/green ASG replacement, and measure how long tag joining lags a
new ASG. If `AWS/AutoScaling` is not covered, `in_service_capacity` falls back
to legacy dimension mode with a documented re-apply-after-deploy limitation; if
`AWS/EC2` is not covered, `cpu` falls back to the agent-side `cpu_usage_idle`
metric (`AVG < 100 - threshold`, `WHERE AppName`, `GROUP BY InstanceId`), which
needs no config change.

> **RESOLVED 2026-07-31 — NEGATIVE.** A real apply returned `ValidationError:
> Metrics expression that return multi time series are only allowed for
> MetricsInsights expression with an ORDER BY clause`. `PutMetricAlarm` requires
> every backing expression to return a single time series; the sole exception is
> a Metrics Insights expression carrying `ORDER BY`, which `DIFF(q1)` is not
> (and `RATE()` would not be either, retiring fallback 2 as well). `gc_time` was
> removed per fallback 3. The surviving `GROUP BY` alarms — JMX `heap_used`, ASG
> `cpu`/`memory`/`disk` — gained `ORDER BY AVG() DESC`, which was missing and
> would have failed the same way. Per-series contributor semantics do hold once
> `ORDER BY` is present.

**2. `PutMetricAlarm` must accept `DIFF()` over a multi-series query, and the
resulting alarm must evaluate per series.** Graphing an expression does not
prove it can back an alarm. Before any real apply, create one alarm by hand,
confirm it leaves `INSUFFICIENT_DATA`, and confirm `StateReason` names the
individual breaching series rather than a single collapsed value. If the alarm
state is not per-series, contributor semantics are absent and `gc_time` must
fall back to the alternatives below.

Fallbacks, in order of preference:

1. **Emit deltas at the agent** — if the JMX receiver can publish
   `jvm_gc_collections_elapsed` with delta temporality, `DIFF` becomes
   unnecessary altogether.
2. **PromQL `rate()`** — `rate(jvm_gc_collections_elapsed{AppName="v"}[1m])`,
   contingent on CloudWatch supporting alarms on PromQL queries. Handles counter
   resets natively, which would also remove the JVM-restart caveat.
3. **Drop `gc_time`, keep `heap_used`** — the position the 2026-07-24 spec
   originally took: heap exhaustion and GC thrash almost always arrive together.

## Rejected alternatives

- **Making Name tags unique per fleet instance.** Fixes the precondition failure
  but not the drift: instance IDs still churn every deploy.
- **Keeping `heap_used` in the ASG module and adding `gc_time` beside it.**
  Least work now, but the ASG module keeps absorbing measurements it does not
  own and every JVM alarm gets written twice.
- **Unifying every module on query-scoped identity and deleting Name-tag
  lookups.** Standalone hosts sharing a group tag would collapse into one alarm,
  and per-host scoping of CWAgent metrics would need a config copy per box —
  `AppName` is the only per-host discriminator the agent emits.
- **`SCHEMA()` with an explicit dimension list for CWAgent metrics.** Requires
  an exact match, so any dimension the receiver adds silently breaks every
  alarm — and it breaks in the green direction.
- **`RATE()` instead of `DIFF()`.** Period-independent, but unverified for
  multi-series and it changes the threshold unit for no active benefit.

## Testing

- `terraform init -backend=false && terraform validate` in the `jmx`, `asg` and
  `ec2` modules and in `stacks/projects/billing/dev`.
- Fixture plans rendering: a legacy ASG entry, a fleet ASG entry, and JMX
  entries with and without `process_group`. Assert the generated query strings
  and the computed heap byte threshold character by character.
- `python3 -m json.tool` on both cwagent templates with placeholders
  substituted.
- Preflight scripts: `bash -n`, plus stub-`aws` runs covering the skip path, a
  normal entry, and an entry with `process_group`.
- Work machine: the blocking verify item above; then apply one JMX entry against
  a real fleet, replace an instance, and confirm the alarm tracks the successor
  with no Terraform run.

## Out of scope

- Wiring `config.yaml` + `yamldecode` into the stacks. `config.yaml.example`
  exists but no stack reads it; the live input is still `terraform.tfvars`.
  Separate work.
- An `app_name` mode for the `ec2` module.
- Parameter Store upload, JMX port exposure, instance/ASG tagging, and the
  CloudWatch "resource tags on telemetry" account setting — all work-machine
  concerns, as in the 2026-07-24 spec.
