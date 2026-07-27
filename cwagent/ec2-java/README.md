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
