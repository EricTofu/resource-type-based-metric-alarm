# CloudWatch Agent — JMX / JVM metrics

> **Superseded by `cwagent/ec2-java/`.** This config appends only `InstanceId`
> and no `AppName`, so hosts running it cannot be monitored by the JMX alarm
> module, which is `AppName`-scoped. Migrate Java hosts to
> `cwagent/ec2-java/`. Kept for reference and for the metric-name contract.

Collects JVM metrics from a Java app exposing JMX on `localhost:9999` and publishes
them to CloudWatch.

**Nothing in this repo consumes the contract below.** The JMX alarm module
(`modules/cloudwatch/metrics-alarm/jmx`) and the JVM dashboard
(`modules/cloudwatch/dashboard/jmx`) both filter on the CWAgent `AppName`
dimension, which this config does not append — so a host running this config
publishes JVM metrics that those alarms cannot see, and because both alarms are
`treat_missing_data = "notBreaching"` they stay green forever rather than failing.
Use `cwagent/ec2-java/` for any host that is meant to be alarmed. The metric-name
and collection-interval contract here is kept only as reference for the metric
names themselves (which `cwagent/ec2-java/` shares).

## Contract (reference only — no alarm or dashboard reads it)

- **Namespace:** `CWAgent`
- **Dimension:** `InstanceId` (added via `append_dimensions`). Notably **no
  `AppName`** — that is the reason this config is superseded.
- **Metrics:** `jvm_memory_heap_used`, `jvm_memory_heap_committed`, `jvm_memory_heap_max`,
  `jvm_gc_collections_count`, `jvm_gc_collections_elapsed`, `jvm_threads_count`,
  `jvm_classes_loaded` (snake_case, renamed at the agent from the OTel dotted names)
- **Collection interval:** `metrics_collection_interval: 60` is pinned inside the `jmx`
  block. Keep the pin when merging this snippet into an existing agent config: the
  JMX alarms' `gc_time` expression is `DIFF()` over a cumulative counter at
  `period = 60`, i.e. ms of GC per minute, and a collection interval below the
  period puts more than one datapoint in a period and distorts that delta.

## Prerequisites

- `amazon-cloudwatch-agent` with JMX support installed on the host.
- The JVM runs with a **bounded heap** (`-Xmx`). Without it `jvm_memory_heap_max` is
  reported as `-1`. The heap alarm is a **static byte threshold**
  (`heap_threshold` % × the `heap_max_bytes` given in tfvars), so an unbounded heap
  does not break the expression — it breaks the premise: there is no real ceiling
  for the configured threshold to be a percentage of. `scripts/check_jmx_metrics.sh`
  reconciles `heap_max_bytes` against the observed `jvm_memory_heap_max` (±10%) and
  fails the preflight on a mismatch, which is how both an unbounded heap (`-1`) and a
  plain tfvars/`-Xmx` typo surface. A bounded heap is assumed.
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

## Verify metrics are flowing (agent-level only — not an alarm readiness check)

You should see **two** kinds of series per JVM metric: the fully-dimensioned one (carrying
`InstanceId` plus dimensions the JMX receiver adds itself, e.g. `ProcessGroupName` and a
per-collector `name` on the GC metrics) **and** a series with **only `InstanceId`** — the
`aggregation_dimensions: [["InstanceId"]]` rollup:

    aws cloudwatch list-metrics --namespace CWAgent --metric-name jvm_memory_heap_used
    aws cloudwatch list-metrics --namespace CWAgent --metric-name jvm_gc_collections_elapsed

Seeing both proves the agent is publishing, and that is all it proves. It does **not**
mean the JMX alarms will work: they filter `WHERE AppName = '<v>'`, and neither series
here carries an `AppName` dimension, so both are invisible to them. Run
`scripts/check_jmx_metrics.sh --tfvars <path>` — it runs the alarms' own queries — to
verify the thing the alarms actually read.

**GC and the per-collector series.** The underlying OpenTelemetry JMX `jvm` target emits
one series **per garbage collector** (e.g. "G1 Young Generation", "G1 Old Generation")
— a `name` dimension — under its native OTel dotted metric name; the CloudWatch Agent
renames each to `jvm_gc_collections_elapsed` / `_count` (the `rename` field in the
contract above) before publishing. Total time-in-GC therefore requires summing across
collectors. **History:** an earlier design of the `gc_time` alarm did that server-side by
reading the `{InstanceId}` rollup with `stat = "Sum"`. The current alarm has **no `stat`**
at all — it is a Metrics Insights query, `SELECT SUM(jvm_gc_collections_elapsed) … GROUP BY
InstanceId` wrapped in `DIFF()`, where the `SUM` is the SQL aggregate doing the same
cross-collector totalling on the full-dimension series. The rollup is not involved.
Either way JMX must be collected at 60s (= the alarm period) so there is one datapoint
per period; the shipped config pins `metrics_collection_interval: 60` inside the `jmx`
block for that reason, and the pin must survive a merge into an existing agent config.

> Dimension notes: this config appends only `InstanceId`, which is precisely why it
> cannot feed the JMX alarms — they need `AppName`. Adding `ImageId`/`InstanceType` to
> `append_dimensions` is possible but just raises metric cardinality/cost. The
> `{InstanceId}` rollup collapses `ProcessGroupName`, so on a host running **multiple**
> JVMs the rolled-up JVM metrics are aggregated together; the JMX module handles that
> case instead by scoping its queries with `process_group`
> (`AND ProcessGroupName = '<v>'`) on the full-dimension series — which again needs
> `cwagent/ec2-java/`.

## Liveness is NOT covered by these alarms

`heap_used`/`gc_time` use `treat_missing_data = "notBreaching"`, so a crashed JVM or a
stopped agent (no JVM metrics → INSUFFICIENT_DATA) will **not** fire them. Pair the JMX
alarms with the EC2 module's `status_check` alarm (missing-data = breaching) on the same
host so a dead app/instance is still caught. Don't deploy JMX as the sole signal.
