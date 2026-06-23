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

    module "jvm_dashboard" {
      source = "../../../../modules/cloudwatch/dashboard/jmx"
      project   = var.project
      env       = var.env
      region    = var.aws_region
      instances = [
        { name = "billing-java-app-1", instance_id = "i-aaaa" },
        { name = "billing-java-app-2", instance_id = "i-bbbb" },
      ]
    }

To regenerate this static file from the module after a layout change:

    terraform -chdir=<stack> output -raw <module>_dashboard_json > dashboards/jmx-jvm.json
