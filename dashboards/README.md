# Dashboards

## jmx-jvm.json — JVM / JMX dashboard

Per-host-group JVM view sourced from the CloudWatch Agent config in `cwagent/ec2-java/`
(JVM metric names are snake_case, e.g. `jvm_memory_heap_used`, `jvm_gc_collections_elapsed`).
Every series is a Metrics Insights query scoped by the CWAgent `AppName` dimension and
grouped by `InstanceId`, so each widget shows one line per live instance in the host
group and follows fleet churn (instances added/removed by an ASG or CodeDeploy) with no
Terraform run. There is no per-instance heap-percentage view: CloudWatch math cannot
divide two `GROUP BY` series arrays, so heap is charted in bytes only.

Three widgets per host group:

- **Heap (bytes)** — `jvm_memory_heap_used` (one line per instance) plus a single
  `jvm_memory_heap_max` line.
- **GC time (ms/min)** — `DIFF()` of the cumulative `jvm_gc_collections_elapsed` counter
  (GC time/min) and of `jvm_gc_collections_count` (GC cycles/min).
- **Threads & classes** — `jvm_threads_count` and `jvm_classes_loaded`.

Two ways to use it:

### Import the static JSON (console)
`dashboards/jmx-jvm.json` is a snapshot for a single host group (`AppName =
'billing-java-app-1'`). To reuse it for a different group, substitute that `AppName`
value in every query's `expression` and the `region` fields, then create the dashboard:

    aws cloudwatch put-dashboard --dashboard-name my-jvm \
      --dashboard-body file://dashboards/jmx-jvm.json

Or paste it into **CloudWatch → Dashboards → Create → Actions → View/edit source**.

### Terraform (single source of truth)
Use the module — its widgets are built from `targets` (host-group labels), not resolved
instance IDs, so there is nothing to look up:

The billing/dev stack already wires this: set `jmx_dashboard_enabled = true` (with a
non-empty `jmx_resources`) and the dashboard is built for the same host groups the JMX
alarms watch, using the alarm module's `dashboard_targets` output — no hardcoded IDs
(mirrors `stacks/projects/billing/dev/main.tf`):

    module "jmx_dashboard" {
      source = "../../../../modules/cloudwatch/dashboard/jmx"
      count  = var.jmx_dashboard_enabled && length(var.jmx_resources) > 0 ? 1 : 0

      project = var.project
      env     = var.env
      region  = var.aws_region
      targets = module.jmx_alarms[0].dashboard_targets
    }

`dashboards/jmx-jvm.json` is a **generated snapshot** — treat the module as the single
source of truth and regenerate the file (work machine, after apply) whenever the module
layout changes:

    terraform -chdir=stacks/projects/billing/dev output -raw jmx_dashboard_json > dashboards/jmx-jvm.json

(then check the diff only changes what you intended — the rendered body already carries
the real `AppName` value(s); there is no instance-id placeholder to re-insert).
