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
