# ASG Fleet Alarms + Java-EC2 CWAgent Config — Design

**Date:** 2026-07-24
**Status:** Approved pending work-machine verification items
**Targets:**
- `modules/cloudwatch/metrics-alarm/asg/` — rework into fleet module
- `modules/cloudwatch/metrics-alarm/ec2/` — add `disk` alarm only
- `cwagent/ec2-java/` — new first-class config template (reference copy of the
  Parameter Store config)
- `scripts/check_asg_fleet_metrics.sh` — new preflight
- **Branch dependency:** builds on `fix/efs-jmx-review-fixes` (cwagent/ layout,
  JMX module conventions); this branch is rebased onto it and must land after it.

## Problem

The EC2 module resolves instance IDs from Name tags at plan time. For ASG-backed
instances under CodeDeploy blue/green, both the instance IDs and the ASG name
(suffix) change on every deployment, so dimension-pinned alarms drift into
watching dead resources. `treat_missing_data` settings then either false-alarm
(breaching) or go silently green (notBreaching). Scheduled re-applies and an
EventBridge→Lambda controller were both evaluated and rejected (silent failure
modes; see Rejected alternatives).

Additionally: most EC2s (fleet and standalone) run Java with a large fixed heap
(e.g. `-Xmx12G` on 16G hosts). OS `mem_used_percent` sits at 75–85% by design
(the JVM keeps its heap), so it cannot detect heap leaks — those GC-thrash and
OOM while OS memory stays flat. JVM metrics are the priority signal, which
makes the CWAgent config **as important as the alarm modules**: the alarms are
only as real as the metrics feeding them. Rollout order per host:
(1) CWAgent config in Parameter Store → (2) Java exposes the JMX port →
(3) metrics flow → (4) alarms apply.

## Identity model

- **`AppName`** (CWAgent static dimension + EC2/ASG resource tag) identifies
  **exactly one fleet** — a set of interchangeable instances running the same
  Java process group. One AppName = one ASG lineage (or one standalone group).
  This is the alarm scoping key: tfvars `app_name` = tag value = dimension
  value. Uniqueness per fleet is a contract requirement.
- **`ProcessGroupName`** (CWAgent static dimension on `jmx` only) names the
  Java process within the fleet (e.g. `chat-server-tomcat`). Not a fleet key;
  optionally used to scope the heap alarm when a host ever runs >1 JVM.
- The ASG name (churning suffix) and instance IDs are **never** used as keys.
  Metrics Insights `WHERE` is exact-match only (no wildcards), so the stable
  ASG name *prefix* is unusable — tags/dimensions are the identity carriers.

## Decision summary

| Decision | Choice |
|---|---|
| Module shape | Rework ASG module into a *fleet* module; EC2 module keeps its Name-tag pattern for steady boxes and gains only a new `disk` alarm |
| Drift-proofing | CloudWatch Metrics Insights query alarms scoped by `AppName` — membership resolves at alarm evaluation time, not apply time |
| Granularity | Per-instance via `GROUP BY InstanceId` (multi-series contributor alarms, Sept-2025 CloudWatch feature) for cpu/heap/memory/disk; single-series for capacity |
| Alarm set | Capacity watchdog + per-instance CPU, JVM heap (primary memory signal), OS memory (guardrail), disk. **No status-check alarms in fleet mode** — ASG health checks replace failed instances; the capacity alarm fires when self-healing can't keep up. Pressure alarms stay: static ASGs don't heal pressure, and nothing heals a leak |
| Fleet JVM shape | Byte threshold on `jvm.memory.heap.used` (fleet is homogeneous, `-Xmx` known) — CloudWatch math cannot divide two `GROUP BY` series arrays, so the JMX module's `100*used/max` ratio does not port. GC-time alarm deferred (multi-series `DIFF()` unverified) |
| CWAgent config | One template `cwagent/ec2-java/` for **both** fleet and standalone Java hosts; per-fleet values (`AppName`, `ProcessGroupName`, JMX endpoint, log paths) substituted in the Parameter Store copy. Contract is a floor: extra plugins/metrics allowed |
| Back-compat | `app_name` optional per ASG resource; omitted → exactly today's legacy `AutoScalingGroupName`-dimension capacity alarm, no plan churn. EC2 `disk` follows the `memory` pattern; agentless boxes opt out via `disabled_alarms`. Template preserves the `cwagent/jmx/` contract (`[InstanceId]` rollup, `jvm.*` names, 60s) so JMX-module alarms keep working on hosts that adopt it |

## ASG module interface

```hcl
variable "resources" {
  type = list(object({
    name             = string                 # logical fleet name → alarm naming
    desired_capacity = number
    app_name         = optional(string)       # stable tag+dimension value; null = legacy mode
    heap_max_bytes   = optional(number)       # -Xmx in bytes; required in fleet mode unless heap_used disabled
    process_group    = optional(string)       # optional extra WHERE for heap alarm (multi-JVM hosts)
    enabled          = optional(bool, true)
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
      cpu_threshold      = optional(number)   # new
      memory_threshold   = optional(number)   # new (guardrail)
      heap_threshold_pct = optional(number)   # new, % of heap_max_bytes
      disk_threshold     = optional(number)   # new
      disabled_alarms    = optional(set(string), [])
    }), {})
  }))
}
```

Module-level additions: `app_tag_key` (default `"AppName"` — the EC2/ASG tag
key used by native-metric queries), `default_cpu_threshold` (85),
`default_memory_threshold` (**90** — guardrail semantics, deliberately higher
than the EC2 module's), `default_heap_threshold_pct` (85),
`default_disk_threshold` (85). Validation: `disabled_alarms` ⊆
`{in_service_capacity, cpu, memory, heap_used, disk}`; fleet-only fields are
rejected on legacy entries (`app_name = null`); `heap_max_bytes` required iff
fleet mode and `heap_used` not disabled.

Existing conventions carry over unchanged: naming
`{Project}-{Env}-ASG-[{name}]-{MetricName}` via `local.name_prefix`,
`[{SEVERITY}]-` description prefix, severity → SNS routing, `alarm_arns` /
`alarm_names` outputs keyed `"<name>:<metric>"`, tags block.

## Fleet-mode alarms (per entry with `app_name = v`)

All are `metric_query`-based Metrics Insights alarms (a Terraform alarm cannot
mix `dimensions` with `metric_query`, so fleet and legacy are separate resource
blocks with mode-filtered `for_each`; keys stay `res.name` in both modes —
flipping a resource's mode recreates its alarm, which is expected).

CWAgent-fed queries use plain `FROM "CWAgent"` (not `SCHEMA()`): agent series
carry extra dimensions (`path`/`fstype` on disk, `ProcessGroupName` on JMX),
and `SCHEMA()` requires the exact dimension set while plain `FROM` + `WHERE`
+ `GROUP BY` tolerates them.

| ID | Query | Evaluation |
|---|---|---|
| `in_service_capacity` | `SELECT SUM(GroupInServiceCapacity) FROM SCHEMA("AWS/AutoScaling", AutoScalingGroupName) WHERE tag.AppName = 'v'` | `LessThanThreshold desired_capacity` (or `capacity_threshold`), 10 × 60s, missing = **breaching**. ERROR |
| `cpu` | `SELECT AVG(CPUUtilization) FROM SCHEMA("AWS/EC2", InstanceId) WHERE tag.AppName = 'v' GROUP BY InstanceId` | any series `> cpu_threshold`, 3 × 300s, missing = notBreaching. WARN |
| `heap_used` | `SELECT AVG(jvm.memory.heap.used) FROM "CWAgent" WHERE AppName = 'v' [AND ProcessGroupName = 'pg'] GROUP BY InstanceId` | any series `> heap_threshold_pct% × heap_max_bytes` (bytes, computed in module), 3 × 300s, missing = notBreaching. WARN |
| `memory` | `SELECT AVG(mem_used_percent) FROM "CWAgent" WHERE AppName = 'v' GROUP BY InstanceId` | any series `> memory_threshold` (guardrail, default 90), 3 × 300s, missing = notBreaching. WARN |
| `disk` | `SELECT AVG(disk_used_percent) FROM "CWAgent" WHERE AppName = 'v' AND path = '/' GROUP BY InstanceId` | any series `> disk_threshold`, 3 × 300s, missing = notBreaching. WARN |

Notes:

- `GROUP BY InstanceId`: one series per instance; ALARM when **any** series
  breaches (contributor semantics). Membership re-resolves every evaluation —
  churn requires no Terraform run.
- `SUM` on capacity intentionally counts old+new ASGs during blue/green
  overlap: over-counting briefly masks (never false-fires) a
  `LessThanThreshold` alarm.
- Capacity missing = breaching preserves "fleet vanished → scream" and
  survives ASG replacement (tag matches the successor immediately). All
  per-instance alarms are notBreaching: series legitimately vanish during
  deploys; "everything vanished" is the capacity alarm's job.
- Memory-signal roles: `heap_used` primary; `memory` at 90 catches
  off-heap/native leaks, rogue sidecars, swap risk. Fleet GC-time alarm
  **deferred** (multi-series `DIFF()` unverified; heap exhaustion and GC
  thrash almost always arrive together).
- Period 300 works with basic monitoring; period 60 would require detailed
  monitoring on the launch template.
- Native-metric queries depend on **tag telemetry**; if verify item 2 fails,
  the documented fallback for `cpu` is agent-side `cpu_usage_idle`
  (`AVG < 100 - threshold`, `WHERE AppName`, `GROUP BY InstanceId`) — already
  collected with `AppName`, zero config change.

## EC2 module: new `disk` alarm (only change)

Classic alarm mirroring the existing `memory` alarm: namespace `CWAgent`,
metric `disk_used_percent`, `dimensions { InstanceId, path = "/" }`,
`> disk_threshold` (per-resource `overrides.disk_threshold` →
`default_disk_threshold`, 85), 3 × 300s, notBreaching, WARN. `disk` joins the
module's `disabled_alarms` valid set — agentless boxes disable `memory` +
`disk`, unchanged convention. Feeds on the template's
`[["InstanceId","path"]]` rollup (a classic alarm's dimensions must match the
series exactly; the raw disk series also carries `fstype`).

## CWAgent config template (`cwagent/ec2-java/`)

First-class deliverable. The repo holds the reference template + README
contract; the live copy lives in **SSM Parameter Store** (one parameter per
fleet / host group) with the placeholders substituted. Shipping to hosts
(user-data fetch + `amazon-cloudwatch-agent-ctl -a fetch-config -c ssm:...`)
is the work machine's side.

```json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "<app-log-path>",
            "log_group_name": "<log-group>",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 180
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"], ["InstanceId", "path"]],
    "metrics_collected": {
      "jmx": [
        {
          "endpoint": "<jmx-endpoint e.g. localhost:9999>",
          "jvm": {
            "measurement": [
              "jvm.classes.loaded",
              "jvm.gc.collections.count",
              "jvm.gc.collections.elapsed",
              "jvm.memory.heap.committed",
              "jvm.memory.heap.max",
              "jvm.memory.heap.used",
              "jvm.memory.nonheap.committed",
              "jvm.memory.nonheap.max",
              "jvm.memory.nonheap.used",
              "jvm.threads.count"
            ]
          },
          "append_dimensions": {
            "ProcessGroupName": "<process-group>",
            "AppName": "<app-name>"
          }
        }
      ],
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_iowait", "cpu_usage_user", "cpu_usage_system"],
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "disk": {
        "measurement": ["disk_used_percent", "disk_inodes_free"],
        "resources": ["/"],
        "drop_device": true,
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "net": {
        "measurement": ["net_bytes_recv", "net_bytes_sent"],
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "diskio": {
        "measurement": ["diskio_io_time"],
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "swap": {
        "measurement": ["swap_used_percent"],
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "netstat": {
        "measurement": ["netstat_tcp_established", "netstat_tcp_time_wait"],
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "processes": {
        "measurement": ["processes_running", "processes_total"],
        "append_dimensions": { "AppName": "<app-name>" }
      },
      "ethtool": {
        "metrics_include": [
          "bw_in_allowance_exceeded",
          "bw_out_allowance_exceeded",
          "conntrack_allowance_exceeded",
          "linklocal_allowance_exceeded",
          "pps_allowance_exceeded"
        ],
        "append_dimensions": { "AppName": "<app-name>" }
      }
    }
  }
}
```

### Fixes vs the current stg config

1. **`aggregation_dimensions [["ProjectName"]]` → `[["InstanceId"], ["InstanceId","path"]]`.**
   No `ProjectName` dimension exists anywhere in the config, so the current
   rollup is a no-op. The replacement serves the classic alarms on standalone
   hosts: `[InstanceId]` feeds the EC2 `memory` alarm and the JMX module's
   heap/GC alarms (its documented contract), `[InstanceId, path]` feeds the
   new EC2 `disk` alarm. Fleet Insights queries read the full-dimension
   series and ignore rollups. Cost note: each rollup adds one series per
   metric — accepted for a single shared template.
2. **`ebs` section deleted** (already dropped by Eric): not a CWAgent plugin;
   `volume_queue_length` is the free native `AWS/EBS` `VolumeQueueLength`
   metric — an EBS alarm module would be its home.
3. **`region` removed from `agent`**: auto-detected from IMDS; keeps the
   template env-agnostic across accounts.
4. **`disk.resources: ["/"]` added**: bounds collection to the root mount the
   alarm watches (the current config collects every mount, incl. tmpfs
   noise). Add data mounts (e.g. `/apps`) to the list — and, later, to the
   alarm — as needed.
5. **JSON nesting normalized** (the pasted `cpu.append_dimensions` was
   mis-indented; valid but easy to mis-edit).
6. Placeholders (`<app-name>`, `<process-group>`, `<jmx-endpoint>`,
   `<app-log-path>`, `<log-group>`) are the complete per-fleet substitution
   surface — everything else is identical across fleets. README documents
   each.

### Contract (README, floor not ceiling)

Namespace `CWAgent`; dimension `AppName` on every metrics plugin (value =
tfvars `app_name` = EC2/ASG tag value); `ProcessGroupName` on `jmx`;
`InstanceId` via global `append_dimensions`; 60s interval; `jvm.*` OTel metric
names; rollups `[InstanceId]` and `[InstanceId, path]` preserved for
classic-alarm consumers. Never append `${aws:AutoScalingGroupName}` as an
identity key (churns). Extra plugins/metrics are allowed. JVM must expose the
JMX port the config names (rollout order: Parameter Store config → JMX port →
metrics flowing → alarms).

Collected-but-not-alarmed (future candidates, recorded so they aren't
re-litigated): `swap_used_percent` (companion to the memory guardrail),
`ethtool` allowance-exceeded (EC2 network throttling), `disk_inodes_free`
(inode exhaustion), `cpu_usage_iowait`, per-mount disk, JMX
threads/nonheap/GC-rate.

## Out-of-repo prerequisites (work machine)

1. Parameter Store parameter per fleet from the template; agent fetches via
   `ssm:` config source; agent restart on config change.
2. Java processes expose the JMX endpoint named in the config.
3. Launch template propagates `AppName = <v>` tag to instances **and** the
   ASG itself (for `AWS/AutoScaling` tag queries), surviving CodeDeploy
   blue/green.
4. CloudWatch account setting "resource tags on telemetry" enabled per
   account (each env is its own account).

## Preflight

New `scripts/check_asg_fleet_metrics.sh --tfvars <path>`, wired into
`.github/workflows/preflight.yml` alongside the existing checks. For each
fleet entry (`app_name` set): verify (1) running instances carry
`tag:<app_tag_key> = <v>`, (2) CWAgent series exist for `mem_used_percent`,
`disk_used_percent`, and (if heap alarm active) `jvm.memory.heap.used` with
dimension `AppName = <v>`, (3) the tag-scoped `GroupInServiceCapacity` query
returns data, (4) if heap alarm active: latest `jvm.memory.heap.max`
datapoint ≈ tfvars `heap_max_bytes` (catches a tfvars/-Xmx mismatch before it
skews the byte threshold). Rationale: all per-instance alarms are
notBreaching — a mis-dimensioned fleet would sit green forever (same failure
class the JMX preflight guards).

## Verification items (hand-test before rollout; blocking)

1. **Multi-series query alarm via Terraform**: create one `GROUP BY` alarm
   with `aws_cloudwatch_metric_alarm` on the work machine; confirm
   plan/apply/evaluation behavior. Feature is ~10 months old; provider
   support unconfirmed.
2. **Tag telemetry covers `AWS/AutoScaling`**: if not, `in_service_capacity`
   falls back to legacy dimension mode with a documented
   re-apply-after-deploy limitation; per-instance alarms are unaffected
   (and `cpu` has the agent-metric fallback).
3. **Config edits land**: after updating the Parameter Store config
   (`aggregation_dimensions` fix, `disk.resources`), confirm via
   `list-metrics` that the `[InstanceId]`/`[InstanceId,path]` rollups appear
   and JMX heap series collapse to one series per instance under
   `GROUP BY InstanceId`. (Static plugin-level dims are already proven on
   stg: `AppName`/`ProcessGroupName`.)
4. Metrics Insights alarms query only recent (~3h) data and require period
   ≥ 60s — confirm evaluation is stable with basic monitoring at period 300.
5. **Deferred, revisit later**: fleet GC-time alarm — whether `DIFF()` (or an
   equivalent) works over multi-series Metrics Insights results.

## Rejected alternatives

- **Scheduled/pipeline-triggered re-apply** — gap-shaped blind spot, alarm
  recreation churn, `-target` workflow hazards.
- **EventBridge → Lambda controller** — second control plane whose failure
  mode is silent; needs a reconciler, then a reconciler-monitor.
- **ASG-name-prefix matching** — Metrics Insights `WHERE` supports only
  `=`, `!=`, `AND`; no wildcards/regex.
- **Per-instance status-check alarms in fleet mode** — ASG health checks
  already replace failed boxes; capacity alarm covers "healing not keeping
  up".
- **OS `mem_used_percent` as primary fleet memory signal** — permanently
  ~75–85% under `-Xmx12G/16G`; blind to heap leaks. Kept only as a 90%
  guardrail.
- **Fleet heap alarm as `100*used/max` ratio** — CloudWatch metric math
  cannot divide two multi-series arrays elementwise; byte threshold from
  known `-Xmx` is equivalent for a homogeneous fleet.
- **Tag-driven auto-discovery of new resources in Terraform** — reacts only
  at apply time, reshuffles state, and pushes per-resource intent into
  console-editable tags, against the committed-config mandate. *Future idea
  (not planned):* an account-wide catch-all module (generic `GROUP BY`
  alarms, no per-resource config) as a coverage floor beside the explicit
  modules.

## Testing

- `terraform init -backend=false && terraform validate` in the ASG and EC2
  modules (legacy-only, fleet-only, and mixed `resources` fixtures via a
  scratch tfvars/plan where useful).
- `python3 -m json.tool` on the template (placeholders substituted with dummy
  values) to guard JSON validity.
- Work-machine: hand-create verification alarm (item 1), then apply one real
  fleet entry in a dev stack; kill/replace an instance and confirm the alarm
  tracks the successor without a Terraform run; run the preflight script
  against the dev tfvars.
