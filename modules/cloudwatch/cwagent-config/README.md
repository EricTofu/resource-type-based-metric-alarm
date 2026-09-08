# `cwagent-config` — agent config → SSM Parameter Store

**Prototype.** One `aws_ssm_parameter` per host group. It manages the agent's
*config*, not the agent: nothing here installs, restarts, or runs anything.

This is the first module in the repo that writes the **emitting** side of the
identity contract. Every other module asks CloudWatch for series matching
`<cwagent_dimension_key> = '<value>'`; this one decides what the agent stamps.
One stack variable feeds both.

## Where a config comes from

```
templates/base.json.tftpl          what every Linux host reports — cpu, mem,
                                   disk, net, swap, diskio, netstat, processes,
                                   ethtool. Nothing app-specific.
<template_dir>/<entry.template>    what the APP is: its `logs` block and its
                                   `jmx` block, plus any host-metric departure
                                   from the base.
identity stamp                     added by the module, after the merge
```

An entry with no `template` is a valid config: host metrics only, no JVM, no log
shipping — a bastion, a build box.

**The merge is depth-limited on purpose.** `merge()` is shallow and this document
is deep, so a plain `merge(base, overlay)` would replace the whole `metrics`
block and silently drop every base plugin. The module merges at three named
depths — top level, `metrics`, and `metrics_collected` — and stops: a plugin the
overlay names is replaced **whole**, never field-merged. `"<plugin>": null` drops
one. `"//"` keys are the overlays' comment idiom and never reach the agent.

**No template writes the fleet identity.** The module stamps
`<cwagent_dimension_key> = <value>` onto every plugin after the merge, so a
plugin a project replaces — or invents next year — is compliant by construction.

That one dimension is all the module owns. Every **other** dimension an app wants
— `ProcessGroupName` on a `jmx` block is the usual one — is written in the
overlay's own `append_dimensions`, beside the plugin it describes, and passes
through the merge untouched: the module's map is merged last, so it wins only on
its own key. The module does not write those and does not check them. A
`ProcessGroupName` the JMX alarms filter on is therefore the overlay's
responsibility, hand-synced with the `jmx_resources` entry's `process_group`
exactly as the dimension *values* have always been.

Overlay variables: `project`, `env`, `name`, `dimension_value`,
`collection_interval`. `name` is what lets two host groups share one overlay file
and still write distinct log group names.

## One guard, because the JVM contract moved into project files

The `jmx` block is where the alarms' contract lives, and it is now per project —
so the module checks the one thing it can:

- **`required_jvm_metrics` must appear among the overlay's renames** — a `check`
  block, so it warns rather than blocks (collecting a subset is legitimate). It
  is a hand-synced mirror of what `metrics-alarm/jmx` queries: Terraform cannot
  read another module's query text. Drop `jvm_memory_heap_used` from an overlay
  and the heap alarm does not error — it goes `notBreaching`. Forever.

It cannot see the *values*: nothing checks that an overlay's snake_case renames
match what the alarms actually query beyond those names, that an overlay declares
the `ProcessGroupName` its `jmx_resources` entry filters on, or that
`cwagent_dimension_value` equals the one on the `asg`/`jmx` entry. Those stay
hand-synced, as they were.

An overlay is less readable than a whole config — "what does this fleet actually
collect?" needs both files. Read the merged truth instead:

```bash
terraform output -json cwagent_config_json | jq -r '."<host group>"' | jq .
```

## What it does not do

Writing the parameter does not restart an agent and does not republish a metric.
A host keeps reporting under its old identity until it re-fetches:

```bash
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c ssm:<parameter_name>
```

Between the apply and that fetch, every CWAgent-sourced alarm (ASG memory/disk,
JMX heap/GC) matches nothing and sits `notBreaching` — green, not red. Verify
with the preflight scripts before trusting the alarms again.

## Notes

- **Parameter name** defaults to `AmazonCloudWatch-<project>-<env>-<name>`.
  `CloudWatchAgentServerPolicy` grants `ssm:GetParameter` only on
  `parameter/AmazonCloudWatch-*`; a name outside that prefix needs an extra IAM
  statement, and its absence fails on the host, where Terraform cannot see it.
- **Size.** Standard tier caps a value at 4096 bytes; the rendered configs are
  1.4–2.3 KB, compacted by a `jsondecode`/`jsonencode` round trip that also turns
  invalid template output into a plan-time error. A `precondition` checks the
  size before the API does; `tier = "Advanced"` is the escape hatch.
- **`metrics_collection_interval`** is coupled to the JMX module's `gc_time`
  threshold — see the variable description and `cwagent/ec2-java/README.md`.
- Entries name their overlay by bare file name because a `*.tfvars` file cannot
  reference `path.root`; the stack passes `template_dir`.
