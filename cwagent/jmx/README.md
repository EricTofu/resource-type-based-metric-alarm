# CloudWatch Agent — JMX / JVM metrics

> **Superseded by `cwagent/ec2-java/`.** This config appends only `InstanceId`
> and no `AppName`, so hosts running it cannot be monitored by the JMX alarm
> module, which is `AppName`-scoped. Migrate Java hosts to
> `cwagent/ec2-java/`. Kept for reference and for the metric-name contract.

Collects JVM metrics from a Java app exposing JMX on `localhost:9999` and publishes
them to CloudWatch. The alarm module (`modules/cloudwatch/metrics-alarm/jmx`) and the
JVM dashboard depend on the contract below.

## Contract (do not change without updating alarms + dashboard)

- **Namespace:** `CWAgent`
- **Dimension:** `InstanceId` (added via `append_dimensions`)
- **Metrics:** `jvm_memory_heap_used`, `jvm_memory_heap_committed`, `jvm_memory_heap_max`,
  `jvm_gc_collections_count`, `jvm_gc_collections_elapsed`, `jvm_threads_count`,
  `jvm_classes_loaded` (snake_case, renamed at the agent from the OTel dotted names)
- **Collection interval:** `metrics_collection_interval: 60` is pinned inside the `jmx`
  block — it must equal the alarm/widget period (60s). Keep the pin when merging this
  snippet into an existing agent config; a shorter inherited interval breaks the
  `gc_time` alarm's `stat = Sum` math (over-counts the cumulative GC counter).

## Prerequisites

- `amazon-cloudwatch-agent` with JMX support installed on the host.
- The JVM runs with a **bounded heap** (`-Xmx`). Without it `jvm_memory_heap_max` is
  reported as `-1`, which makes the heap alarm's `100*used/max` expression negative — it
  would then never fire. A bounded heap is assumed.
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

## Verify metrics are flowing (run on a live host before trusting the alarms)

You should see **two** kinds of series per JVM metric: the fully-dimensioned one (carrying
`InstanceId` plus dimensions the JMX receiver adds itself, e.g. `ProcessGroupName` and a
per-collector `name` on the GC metrics) **and** a series with **only `InstanceId`** — the
`aggregation_dimensions: [["InstanceId"]]` rollup. The alarms and dashboard query the
`{InstanceId}` rollup, so that series must be present:

    aws cloudwatch list-metrics --namespace CWAgent --metric-name jvm_memory_heap_used
    aws cloudwatch list-metrics --namespace CWAgent --metric-name jvm_gc_collections_elapsed

**GC and the per-collector rollup.** The OpenTelemetry JMX `jvm` target emits
`jvm_gc_collections_elapsed` / `_count` **once per garbage collector** (e.g. "G1 Young
Generation", "G1 Old Generation") — a `name` dimension. The `{InstanceId}` rollup sums
across collectors **server-side**, so the `gc_time` alarm and the dashboard read the rollup
with **`stat = Sum`** to get total time-in-GC (`Maximum` would return only the single
busiest collector). This is correct as long as JMX is collected at 60s (= the alarm/widget
period) so there is one datapoint per period — a summed cumulative counter would over-count
if the JMX collection interval were below the period. The shipped config pins
`metrics_collection_interval: 60` inside the `jmx` block for exactly this reason; do not
remove the pin when merging into an existing agent config.

> Dimension notes: `InstanceId` is all the alarms/dashboard need (they hit the rollup).
> The shipped config appends only `InstanceId`; adding `ImageId`/`InstanceType` to
> `append_dimensions` is possible but just raises metric cardinality/cost without
> affecting the alarms. The `{InstanceId}` rollup also
> collapses `ProcessGroupName`, so on a host running **multiple** JVMs their JVM metrics are
> aggregated together; if you need per-process alarms there, target `{InstanceId,
> ProcessGroupName}` instead and pass the process group per resource.

## Liveness is NOT covered by these alarms

`heap_used`/`gc_time` use `treat_missing_data = "notBreaching"`, so a crashed JVM or a
stopped agent (no JVM metrics → INSUFFICIENT_DATA) will **not** fire them. Pair the JMX
alarms with the EC2 module's `status_check` alarm (missing-data = breaching) on the same
host so a dead app/instance is still caught. Don't deploy JMX as the sole signal.
