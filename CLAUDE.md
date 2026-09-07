# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## How to read this file

This file records **decisions, contracts and footguns** — what the code cannot
state about itself. It holds no thresholds, defaults, periods or query text;
those live in the modules, and a second copy here would desync. **A threshold
number in this file is a bug — delete it and point at the module.**

| Question | Authority |
| --- | --- |
| Which metrics exist, thresholds, defaults, query text | the module's `main.tf` / `variables.tf` |
| Which resources are monitored | the stack's `terraform.tfvars` / `config.yaml` |
| Why a design is the way it is | this file, then `docs/superpowers/specs/` |
| What it used to look like | `docs/history/`, `git log` |

## Commands

```bash
# Per-stack (run from stacks/<path>):
terraform init -backend-config=backend.hcl
terraform plan
terraform apply

# Library module validation (no backend):
cd modules/cloudwatch/metrics-alarm/<type>
terraform init -backend=false && terraform validate

terraform fmt -recursive   # from repo root
```

## Architecture

CloudWatch metric alarms for 13 AWS resource types, in three layers:

1. **Library modules** (`modules/cloudwatch/metrics-alarm/<type>/`) — alarm
   definitions, stateless.
2. **Platform stacks** (`stacks/platform/<env>/`) — SNS topics per account,
   state in the Ops bucket.
3. **Project stacks** (`stacks/projects/<project>/<env>/`) — call the library
   modules; read SNS ARNs and the foundation `accounts` map from platform via
   `terraform_remote_state`.

There is no root Terraform configuration. Every `terraform` command runs inside
a stack directory — the legacy monolithic root was removed at M4.

### Two input forms

A leaf reads deploy intent from either `terraform.tfvars`
(`var.<type>_resources`) or a committed `config.yaml` (`yamldecode` into
`local.cfg` / `local.res`) — the latter where an org rule forbids `*.tfvars` in
git. Leaves **in this repo** use tfvars; `config.yaml.example` and
`config_guard.tf.example` under `stacks/projects/billing/dev/` are templates
for leaves that don't.

Both gate each module on a `count` over a list defaulting to empty, so both
share the repo's most dangerous silent failure: **an input no module block
reads produces no alarms and no error.** See "Adding a new resource type",
step 6.

## Module pattern

- `variables.tf` — `project`, `env`, `resources`, `sns_topic_arns`,
  `common_tags`, plus per-metric default variables. `resources` (including
  per-resource `overrides`) and `sns_topic_arns` carry `validation {}` blocks.
- `main.tf` — a `locals` block with a per-metric `default_severities` map, data
  sources resolving resource IDs from names, one `aws_cloudwatch_metric_alarm`
  per metric.
- `outputs.tf` — `alarm_arns` and `alarm_names`, keyed `"<resource-key>:<metric-name>"`.

Threshold resolution is a `coalesce()` chain: per-resource override →
calculated value (where one applies) → module default variable.

### Two different "off" switches — they are not interchangeable

- **`enabled = false`** only empties `alarm_actions` / `ok_actions`. The alarm
  still exists, evaluates, costs, and shows red — it just notifies nobody.
- **`overrides.disabled_alarms`** removes the alarm outright (below).

Picking the wrong one is quiet either way: `enabled = false` expecting no alarm
leaves a permanently red alarm nobody is paged for; `disabled_alarms` expecting
a mute destroys the alarm's history.

> **⚠️ `enabled` is not plumbed through every stack variable.** All 13 modules
> accept it, but a stack's `variables.tf` declares it on only some types.
> Terraform **silently drops** object attributes the target type does not
> declare — no error, no warning, `terraform validate` still passes. So on a
> type whose stack variable omits it, `enabled = false` does nothing and **the
> alarm still pages**. Check the stack's `variables.tf` first.
>
> Same rule in reverse: trimming a field from a module does not remove it from
> stacks and examples. Grep for it; validate will not find it.

### Opting out: `overrides.disabled_alarms`

An optional `set(string)` of metric IDs to skip for one resource. Opt-out, so
the default empty set means every metric is on. Each alarm's `for_each` filters
the resource out entirely, so **no alarm is created** — not created-and-muted,
meaning no cost.

Valid IDs are the resource labels of the module's *active*
`aws_cloudwatch_metric_alarm` blocks, enforced by a `validation {}` block;
commented-out alarms are excluded. Two alarms are gated differently and are not
reachable through `disabled_alarms`: S3 replication is opt-**in** via
`overrides.replication_enabled`, and the Lambda account-level concurrency alarm
is gated by the module input `concurrency_alarm_enabled`.

## Alarm naming

`{Project}-{Env}-{ResourceType}-[{ResourceName}]-{MetricName}`, with the
description prefixed `[{SEVERITY}]-`.

Project-first mirrors the `stacks/projects/<project>/<env>/` layout. Env follows
it because each env is its own account, so env matters for cross-account
dashboards and payloads, not for grouping within an account.

Each module builds the `{Project}-{Env}-{ResourceType}` part once as
`local.name_prefix`. **Change the convention there, never per-alarm** — alarm
names are the CloudWatch API's identity (see the ASG footgun below).

## Severity is a routing contract, not a label

Three levels map to distinct SNS topic ARNs via `var.sns_topic_arns`:

- **CRIT** reaches a pager and wakes someone at any hour.
- **ERROR** reaches chat, handled in working hours.
- **WARN** is a digest, read deliberately.

Classification follows from that, not from how bad a metric sounds. CRIT holds
only user-visible symptoms and liveness — ALB `elb_5xx` / `target_5xx` /
`unhealthy_host` / `target_response_time`, ASG capacity, EC2 status checks, RDS
`engine_uptime`. Causes sit at ERROR until their lead time has been *measured*.
Saturation trends sit at WARN.

Full classification and the promotion criterion a signal must meet to reach
CRIT: `docs/superpowers/specs/2026-07-31-alerting-policy-design.md`.

`apigateway error_5xx` stays WARN **deliberately** — the customer-facing path is
covered by a synthetic canary alarm maintained outside this repo. Do not "fix"
it without first confirming that canary still exists.

CloudFront uses `var.sns_topic_arns_global`, because its metrics exist only in
`us-east-1` and it runs through a separate provider alias.

## Multi-series alarms — the `ORDER BY` rule

Every fleet alarm (ASG `fleet_cpu` / `fleet_memory` / `fleet_disk`, JMX
`heap_used` / `gc_time`) is **one** alarm watching many instances via
`GROUP BY InstanceId`. Each returned series is a *contributor*; the alarm enters
ALARM as soon as any one breaches, and membership re-resolves at every
evaluation. That is what makes CodeDeploy churn free — no re-apply.

Two hard API constraints govern this. Both were learned from a failed apply on
2026-07-31, not from documentation:

1. **`ORDER BY` is mandatory, not decorative.** `PutMetricAlarm` rejects any
   expression returning multiple time series:
   `ValidationError: Metrics expression that return multi time series are only
   allowed for MetricsInsights expression with an ORDER BY clause`. A
   `GROUP BY` query without it passes `terraform validate`, passes
   `get-metric-data` (so it graphs fine and the preflight scripts go green),
   and fails only at apply. `ORDER BY` also selects which 500 series are
   evaluated once a group exceeds that cap — so its *direction* is load-bearing.
   These alarms all fire on high values and order descending accordingly.
2. **Metric math cannot wrap a multi-series query.** The exception above is for
   a *Metrics Insights* expression only. `DIFF()` / `RATE()` over a `GROUP BY`
   query is metric math and is rejected regardless of what it wraps. A math
   expression may back an alarm only when it resolves to a single series — EFS
   `throughput_util` is the one place that holds.

**Corollary for anything new:** graphing a query in `get-metric-data` proves
nothing about whether it can back an alarm. Create one alarm by hand before
building a module around a new query shape.

## Identity carriers: EC2 tags vs CWAgent dimensions

Two independent mechanisms, easy to conflate, and conflating them fails green.

- **`asg_tag_key`** names an **EC2/ASG resource tag key**. Used by exactly two
  queries: the ASG module's capacity alarm (`AWS/AutoScaling`, tag on the ASG)
  and its CPU alarm (`AWS/EC2`, tag on each instance). Requires the
  account-level "resource tags on telemetry" setting — per account **and** per
  region.
- **`cwagent_dimension_key`** names a **CWAgent dimension**: a literal string in
  the agent config, because `append_dimensions` cannot read arbitrary tags.
  Every CWAgent-sourced alarm — ASG memory/disk, all of JMX, every JVM dashboard
  widget — matches on this and ignores resource tags entirely.
- The **`ec2`** module uses neither. It resolves instances by `tag:Name` through
  a data source and then alarms on plain `InstanceId` dimensions, so it is a
  third mechanism and is unaffected by either key.

Both default to `AppName`, which is convenient and misleading: nothing checks
they agree, because they are set in different systems. The ASG module straddles
both — capacity and cpu through the tag, memory and disk through the dimension —
and builds each filter once (`local.tag_filter` / `local.cwagent_filter`) so
which mechanism a query uses is visible at a glance.

The **JVM** identity is neither of them: that is the `ProcessGroupName`
dimension (`process_group`), which is why one fleet identity can cover many JVM
hosts.

The tag on the resources and the `asg_tag_value` / `cwagent_dimension_value` in
the stack are kept in sync **by hand**. The dimension value in the agent config is
the exception where a stack wires `cwagent-config` (see "Agent configs"): there
one apply moves both the emitting and the querying side — though not the hosts.
Drift fails silently green for every alarm except capacity. That is why the
preflight scripts deliberately exercise both a tag-scoped native query and a
dimension-scoped CWAgent query.

### Renaming either key

Both rename a **key** only — never the per-entry *values* (`asg_tag_value`,
`cwagent_dimension_value`), and never each other. Change them at the **caller**: a module
default is shared by every stack, and because a rename alters only
`metric_query.expression` and not `alarm_name`, a wrong one applies in place
with nothing to see in the plan.

**`asg_tag_key`** — three things move together:

1. `var.asg_tag_key` in the stack's `variables.tf`.
2. The tag on the ASG itself.
3. The tag on its instances (`propagate_at_launch` or a launch-template tag
   spec). Both queries need it; neither can see the other's resource.

**`cwagent_dimension_key`** — also three, and it reaches further because one
stack variable feeds the `asg`, `jmx` and `dashboard/jmx` modules (they all read
the same agent config, so separate values would be drift, not flexibility):

1. `var.cwagent_dimension_key` in the stack's `variables.tf`.
2. `append_dimensions` in the agent config, **redeployed to every host**. On a
   stack wiring `cwagent-config` the parameter is rewritten by the same apply, so
   the edit is one variable — but the hosts still have to re-fetch, and until
   they do the queries ask for a dimension nothing emits. Elsewhere the agent
   config is changed out-of-band from `cwagent/ec2-java/`.
3. The JVM dashboard follows automatically — it takes the same variable.

Either way, also update `ASG_TAG_KEY` / `CWAGENT_DIMENSION_KEY` in
`.github/workflows/preflight.yml`: hand-synced mirrors, because Terraform
variables are not readable from a workflow.

**They fail differently, which is the reason to keep them separate.** A broken
`asg_tag_key` splits the two tag alarms on `treat_missing_data` — capacity
(`breaching`) pages forever while cpu (`notBreaching`) sits green. A broken
`cwagent_dimension_key` is worse: ASG memory/disk, JMX heap/GC and every
dashboard widget are all `notBreaching`, so nothing pages, nothing turns red,
and only the preflight scripts notice.

On a YAML leaf both are top-level `config.yaml` scalars that `main.tf` must
consume explicitly — `config_guard.tf` only inspects keys under `resources:`, so
an unconsumed scalar sits there silently.

## Per-module decisions

Defaults, thresholds and query text for each live in its module directory.
Recorded here is only what the code cannot explain about itself.

- **ALB** — `target_groups` is required per resource because UnHealthyHostCount
  is published only per `(TargetGroup, LoadBalancer)`; that alarm fans out one
  per ALB/target-group pair. Omitting `target_groups` is valid only when the
  unhealthy-host alarm is disabled.
- **EC2** — resolves instances via `data.aws_instance` on the Name tag. A
  `check {}` block warns at plan time when the Name tag matches zero or several
  instances. Memory and disk come from the CWAgent namespace, so they need the
  agent installed; the disk series specifically needs the `[InstanceId, path]`
  rollup from `cwagent/ec2-java/`.
- **RDS** — one flat `resources` list with `is_cluster` and `serverless` flags.
  Clusters expand into their members via `data.aws_rds_cluster`. FreeableMemory
  and DatabaseConnections thresholds are calculated from instance-class RAM
  rather than configured. Two alarms are engine-gated off `data.aws_db_instance`:
  FreeStorageSpace for non-Aurora only, EngineUptime for Aurora only — each
  treats missing data as breaching, so on the wrong engine it would sit
  permanently in ALARM.
- **S3** — the replication alarm is opt-in and also needs a destination bucket,
  because the metric exists only per `(SourceBucket, DestinationBucket, RuleId)`.
- **ASG** — see below.
- **Lambda** — `timeout_ms` is required per resource; the duration threshold is
  derived from it. The account-level concurrency alarm is created once, not per
  function.
- **CloudFront** — keyed by `distribution_id`, with `name` optional and used
  only for alarm naming.
- **EFS** — identified by `file_system_id` directly; there is no Name-tag
  lookup because the AWS provider has no tag-filtered EFS data source. Its
  single alarm is the repo's **only metric-math alarm** (throughput utilization
  = metered bytes over permitted throughput). It is watched over a deliberately
  long span to catch a creeping bottleneck rather than short spikes, and treats
  missing data as not breaching, because an idle file system must not alarm.
- **JMX** — see below.
- **ElastiCache / OpenSearch / SES** — no special behaviour; they follow the
  module pattern exactly.

### ASG

Requires `desired_capacity` per resource. Each entry is in one of two modes:

- **Legacy** (no `asg_tag_value`) — the classic `AutoScalingGroupName`-dimension
  capacity alarm.
- **Fleet** (`asg_tag_value` set) — for CodeDeploy-churned ASGs whose instance
  IDs and ASG-name suffix change on every deploy. Four identity-scoped Metrics
  Insights alarms: a capacity watchdog (missing data = **breaching**) and three
  per-instance guardrails grouped by `InstanceId` (missing data = not
  breaching). Membership re-resolves every evaluation, so churn needs no
  re-apply.

The OS-memory guardrail sits high on purpose: JVM hosts run hot by design, and
heap — not OS memory — is the real signal. JVM heap and GC for fleet instances
live in the **JMX** module, keyed by the same `cwagent_dimension_value`.

Identity contract — the entry carries the value once per system, named after the
system that resolves it:

| Field | Resolved against | Alarms |
| --- | --- | --- |
| `asg_tag_value` | the `<asg_tag_key>` tag on the ASG **and** each instance | capacity, cpu |
| `cwagent_dimension_value` | the `<cwagent_dimension_key>` dimension in `cwagent/ec2-java/` | memory, disk |

They are normally the same string, and a validation requires them **set together
or both omitted** — fleet mode cannot be half-configured, because a tag value
without a dimension value leaves memory and disk (both `notBreaching`) green
forever. Both are validated non-empty: an empty string would latch fleet mode and
render `WHERE tag.<key> = ''`, which silently matches nothing.

> **⚠️ Flipping an existing entry between modes takes TWO applies.**
>
> The legacy and fleet capacity alarms render the **same alarm name** by design.
> Latching fleet mode on an entry already in state therefore puts a create and a
> destroy of one CloudWatch alarm in a single plan, with no dependency edge
> between them. `PutMetricAlarm` upserts by name and `DeleteAlarms` deletes by
> name — so if the destroy lands second, it silently removes the CRIT capacity
> watchdog that was just created, while state claims it exists.
>
> Procedure: remove the entry → apply → re-add it with the two `*_value` fields
> → apply. (Or delete the legacy alarm out-of-band and `terraform state rm` it
> before the apply that latches fleet mode.) The same applies in reverse.
>
> A `moved` block cannot express this: it is static and would also move entries
> that stay legacy. The three per-instance fleet alarms have no legacy
> counterpart and are unaffected. See the MIGRATION FOOTGUN comment in the
> module's `main.tf`.

### JMX

Heap and GC alarms for Java apps on EC2, identified by the CloudWatch Agent's
`AppName` **dimension**. There is no instance lookup, so duplicate Name tags
(normal inside an ASG) are irrelevant and blue/green churn needs no re-apply.
One entry covers a whole fleet, or several interchangeable standalone hosts
sharing a `cwagent_dimension_value`.

- `heap_used` is thresholded in **bytes**, not percent, because CloudWatch math
  cannot divide two `GROUP BY` series arrays. `heap_max_bytes` (the JVM `-Xmx`)
  is therefore required unless the alarm is disabled. Don't compute it by hand
  — `scripts/resolve_heap_max.sh` emits it from the observed metric.
- `gc_time` needs no metric math: a `cumulativetodelta` processor on the
  agent's `jmx` pipeline converts the counter before publishing, so it arrives
  as a per-interval delta. **The threshold's meaning is therefore tied to the
  agent's `metrics_collection_interval`** — change one, revisit the other, and
  see `cwagent/ec2-java/README.md`. An earlier `DIFF()` form was wrong twice
  over: rejected by `PutMetricAlarm`, and differencing an already-delta series.
- `process_group` narrows the query to one JVM on hosts running several.
- Alarms treat missing data as not breaching. "The host is gone" is the EC2
  module's status check or the ASG capacity watchdog — both breaching.

Depends on `cwagent/ec2-java/`: namespace `CWAgent`, dimensions `AppName` /
`ProcessGroupName` / `InstanceId`, snake_case `jvm_*` metric names.

> **Known limitation — one identity covers one JVM per host.**
> `cwagent_dimension_value` is validated unique across entries, so a host running two JVMs
> cannot get one entry per `process_group`. Setting `process_group` alarms one
> JVM and leaves the other watched by nothing at all; omitting it averages both
> `ProcessGroupName` series against a single `heap_max_bytes`, so a large JVM
> near OOM is dragged under the threshold by a small idle one and never fires.
>
> This is exactly the silently-green class the design exists to remove,
> accepted only because there are no multi-JVM hosts today. The fix when one
> appears: key uniqueness on the (`cwagent_dimension_value`, `process_group`)
> pair, and reject two entries sharing a `cwagent_dimension_value` where either
> omits `process_group`.

## Dashboards

`modules/cloudwatch/dashboard/jmx/` builds the JVM dashboard with `jsonencode`
and exposes it as `dashboard_json`. Every widget is a Metrics Insights query
scoped by `AppName` and grouped by `InstanceId`, so **widget content resolves at
render time** and follows fleet churn with no Terraform run. Its input is
`targets` — pass the JMX alarm module's `dashboard_targets` output.
`dashboards/jmx-jvm.json` is an importable snapshot of the same layout.

`cwagent/jmx/` (dimension `InstanceId` only) is **superseded** by
`cwagent/ec2-java/`, the full Java-host template that both the alarms and this
dashboard depend on, and the reference for what a rendered config looks like.
Live agent configs are held in SSM Parameter Store, written by `cwagent-config`
below. This repo still manages no compute: nothing here installs, restarts or
runs an agent.

## Agent configs

`modules/cloudwatch/cwagent-config/` publishes the CloudWatch Agent config to SSM
Parameter Store, one parameter per host group. It is the **emitting** side of the
identity contract every other module queries: one stack variable,
`cwagent_dimension_key`, sets both the dimension the agent stamps here and the
dimension the alarm and dashboard queries filter on there.

Each config is assembled from three pieces:

| Piece | Owner | Contains |
| --- | --- | --- |
| `templates/base.json.tftpl` | the module | what every Linux host reports; nothing app-specific |
| `<template_dir>/<entry.template>` | the project stack | what the app is — its `logs` and `jmx` blocks, plus any host-metric departure from the base |
| the identity stamp | the module | the fleet dimension on every plugin, `ProcessGroupName` on `jmx` |

An entry with no `template` is a valid config, not an oversight: host metrics
only, no JVM, no log shipping.

**The merge is depth-limited on purpose.** `merge()` is shallow and the agent
document is deep, so a plain `merge(base, overlay)` replaces the whole `metrics`
block and silently drops every base plugin. The module merges at three named
depths — top level, `metrics`, `metrics_collected` — and stops: a plugin the
overlay names is replaced **whole**, `"<plugin>": null` drops one, and `"//"`
keys are the overlays' comment idiom and never reach the agent.

**No template writes the identity dimensions.** The module stamps them after the
merge, so a plugin a project replaces — or invents later — is compliant by
construction. That makes this the one link in the identity chain that is
mechanical rather than hand-synced.

> **⚠ Terraform's write ends at Parameter Store.** Applying restarts no agent and
> republishes no metric: hosts keep reporting under the old identity until they
> re-fetch. In that window every CWAgent-sourced alarm (ASG memory/disk, JMX
> heap/GC) matches nothing and sits `notBreaching` — green, not red. Changing an
> identity is a two-phase rollout, never one apply.

Because the `jmx` block lives in project files, the snake_case rename contract the
JMX alarms query is per project now and can drift. Two guards, deliberately of
different strength:

- `process_group` missing while an overlay declares `jmx` — a **precondition**,
  which blocks the apply. Without it there is no `ProcessGroupName` dimension for
  the JMX alarms and dashboard widgets to filter on.
- an overlay missing one of `required_jvm_metrics` — a **check block**, which only
  warns, because collecting a subset of the JVM metrics is legitimate. Dropping a
  metric an alarm queries does not error; it goes `notBreaching`. That list is a
  hand-synced mirror of the JMX module's queries, like the key mirrors in
  `.github/workflows/preflight.yml` — Terraform cannot read another module's
  query text.

Parameter naming is load-bearing: `CloudWatchAgentServerPolicy` grants
`ssm:GetParameter` only under the `AmazonCloudWatch-*` prefix, which is why the
module's default name starts there. A name outside it needs an extra statement on
the instance profile, and its absence fails on the host, where Terraform cannot
see it.

## Preflight checks

`scripts/check_*.sh` verify that prerequisite CloudWatch metrics actually exist
*before* alarms are applied. This matters most for the JMX and ASG fleet checks:
those alarms treat missing data as not breaching, so a host missing its agent
config would otherwise sit green forever.

The two Insights-based checks run the alarms' **own** SELECT statements through
`get-metric-data`, each at the period of the alarm it mirrors, so printed values
are directly comparable with configured capacity. They also reconcile each JMX
entry's declared `heap_max_bytes` against the observed maximum.

Three invariants hold across all the scripts. Each exists because a silent pass
is what lets a typo'd identity value reach production green:

1. The tfvars parsers strip line comments before brace counting — a
   commented-out entry is never treated as live, and an unbalanced brace inside
   a comment cannot truncate the list.
2. Matching a `<var>_resources = [` but extracting no entries is an **error**.
   Exit 0 is reserved for a genuinely absent variable or a literal empty list.
3. Each `GROUP BY InstanceId` result is read as a **set** — first series with
   an actual datapoint, plus the series count — never index 0, which can be an
   instance terminated inside the Insights lookback but outside the script's
   window.

On a no-data result the Insights scripts fall back to `list-metrics
--recently-active` to distinguish "metric absent" from "filter matched
nothing". A failed CLI call is reported as an error carrying the CLI's own
message, never as "no data".

Run locally with `--tfvars`:

```bash
scripts/check_ec2_mem_metric.sh --tfvars stacks/projects/<project>/<env>/terraform.tfvars
```

Each script's source is authoritative for its flags and exactly which entries
and metrics it covers.

## CI

- `.github/workflows/terraform-ci.yml` — on PRs touching `modules/**` or
  `stacks/**`: fmt, `terraform validate` per stack and per library module,
  TFLint.
- `.github/workflows/preflight.yml` — on PRs touching
  `stacks/projects/**/terraform.tfvars`: runs the preflight scripts. Needs the
  `PREFLIGHT_READ_ROLE_ARN` secret (a read-only CloudWatch/EC2/S3 role) with
  `cloudwatch:GetMetricData` and `cloudwatch:ListMetrics`.

## Adding a new resource type

1. Create `modules/cloudwatch/metrics-alarm/<type>/{variables,main}.tf`
   following the module pattern above.
2. Add `outputs.tf` exporting `alarm_arns` and `alarm_names`.
3. Add the `<type>_resources` variable to each project stack's `variables.tf`
   that needs it, mirroring the module's `resources` type minus defaults the
   module already applies.
4. Add a `module "<type>_alarms"` block to the stack's `main.tf`, gated
   `count = length(var.<type>_resources) > 0 ? 1 : 0`.
5. Add `<type>` to the stack's `outputs.tf` (both the `alarm_arns` and
   `alarm_names` maps) — **remote-state consumers see only what is exported
   here.**
6. **On a YAML-wired leaf, repeat step 4 there and add `<type>` to
   `local.wired_resource_types`.** Steps 3–4 describe the tfvars form used by
   the leaves in this repo. A `config.yaml` leaf wires the module against
   `try(local.res.<type>, [])` instead, and that mapping does **not** arrive
   with a synced `main.tf`.

   Skipping it is silent in every direction: a `resources:` key no module block
   reads creates nothing, errors nothing, and never runs the library module's
   `validation` blocks — so a typo'd identity inside it is never reported
   either. `config_guard.tf.example` is a drop-in `check {}` that names any
   unconsumed key at plan time. It is the only thing that makes this class of
   miss audible, and **its type list is hand-maintained — update it in the same
   commit.**

## Not currently wired

`modules/cloudwatch/synthetics-canary/heartbeat/` exists and is called by no
stack. Note it takes `project` but not `env`, so it does not yet follow the
alarm modules' naming convention.

`scripts/migrate/` (`generate-split.sh`, `scaffold-leaf.sh`) are one-off
refactor helpers from the M1–M4 split, kept for scaffolding new leaves.
