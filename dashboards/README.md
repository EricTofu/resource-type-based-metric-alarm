# Dashboards

## jmx-jvm.json — JVM / JMX dashboard

Per-instance JVM view (heap used % + bytes, GC time/min, GC cycles/min, threads, classes)
sourced from the CloudWatch Agent JMX metrics (see `cwagent/jmx/`).

Two ways to use it:

### Import the static JSON (console)
`dashboards/jmx-jvm.json` is a one-instance snapshot. Replace `i-PLACEHOLDER` with the
real InstanceId and the `region` fields, then create the dashboard:

    aws cloudwatch put-dashboard --dashboard-name my-jvm \
      --dashboard-body file://dashboards/jmx-jvm.json

Or paste it into **CloudWatch → Dashboards → Create → Actions → View/edit source**.

### Terraform (multi-instance, single source of truth)
Use the module — it builds the body for all instances and creates the dashboard:

The billing/dev stack already wires this: set `jmx_dashboard_enabled = true` (with a
non-empty `jmx_resources`) and the dashboard is built for the same hosts the JMX alarms
watch, using the alarm module's resolved `instance_ids` output — no hardcoded IDs:

    module "jmx_dashboard" {
      source = "../../../../modules/cloudwatch/dashboard/jmx"
      count  = var.jmx_dashboard_enabled && length(var.jmx_resources) > 0 ? 1 : 0

      project   = var.project
      env       = var.env
      region    = var.aws_region
      instances = [for n, id in module.jmx_alarms[0].instance_ids : { name = n, instance_id = id }]
    }

`dashboards/jmx-jvm.json` is a **generated snapshot** — treat the module as the single
source of truth and regenerate the file (work machine, after apply) whenever the module
layout changes:

    terraform -chdir=stacks/projects/billing/dev output -raw jmx_dashboard_json > dashboards/jmx-jvm.json

(then re-insert the `i-PLACEHOLDER` instance id and check the diff only changes what you
intended).
