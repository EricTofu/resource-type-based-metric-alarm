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
| `<jmx-endpoint>` | JMX RMI endpoint the JVM exposes. The Java process must be started with JMX remote enabled on this port. | `localhost:9999` |
| `<app-log-path>` / `<log-group>` | App log shipping (out of alarm scope). | — |

## Contract (floor, not ceiling)

Consumed by `modules/cloudwatch/metrics-alarm/asg` (fleet mode),
`modules/cloudwatch/metrics-alarm/ec2` (memory/disk),
`modules/cloudwatch/metrics-alarm/jmx` (JVM heap/GC alarms — `AppName`-scoped, so
they cover fleet and standalone hosts alike) and `modules/cloudwatch/dashboard/jmx`:

- Namespace `CWAgent`; 60s collection interval.
- Dimension `AppName` (static, plugin-level) on **every** metrics plugin —
  fleet Insights queries filter `WHERE AppName = '<v>'`.
- Dimension `ProcessGroupName` on `jmx`; `InstanceId` via global
  `append_dimensions`.
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
- Never append `${aws:AutoScalingGroupName}` as an identity key — it churns
  on every CodeDeploy blue/green deployment (the exact problem the fleet
  alarms exist to avoid).
- Extra plugins/metrics are allowed (swap, ethtool, netstat, … are collected
  but not alarmed yet; see the spec's future-candidates list).

## Rollout order per host group

1. Parameter Store config created/updated from this template
2. Java process exposes the JMX endpoint
3. Agent restarted; metrics flowing. Verify with the preflight scripts that match
   the entries you are about to add — `scripts/check_asg_fleet_metrics.sh`
   (capacity/cpu/memory/disk), `scripts/check_ec2_mem_metric.sh` (standalone
   memory/disk) and `scripts/check_jmx_metrics.sh` (JVM heap/GC).
4. Alarms applied. JVM alarms are their own list — an ASG or EC2 entry alone gives
   you no heap/GC coverage:
   - `asg_resources` fleet entry (capacity, cpu, memory, disk), or
     `ec2_resources` entry for a standalone host, **and**
   - `jmx_resources` entry (`heap_used`, `gc_time`) with the same `app_name`, plus
     `heap_max_bytes` = the JVM's `-Xmx` in bytes.

Related: `cwagent/jmx/` is the older JMX-only contract. It appends no `AppName`, so
hosts on it are invisible to the JMX alarms; adopting this template supersedes it.

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
