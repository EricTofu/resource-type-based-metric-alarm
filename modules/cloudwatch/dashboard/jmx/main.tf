#------------------------------------------------------------------------------
# JVM / JMX CloudWatch dashboard. Body built with jsonencode (single source);
# `dashboard_json` output is the same body for console import (dashboards/jmx-jvm.json).
# Three widgets per host group: heap bytes, GC time/min, threads + classes.
# Every series is a Metrics Insights query GROUP BY InstanceId, so a widget shows
# one line per live instance and follows fleet churn with no Terraform run.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  # Optional extra scope for multi-JVM hosts; empty string when unset.
  pg_filter = {
    for t in var.targets : t.name =>
    t.process_group != null ? " AND ProcessGroupName = '${t.process_group}'" : ""
  }

  widgets = flatten([
    for idx, t in var.targets : [
      {
        type   = "metric"
        x      = 0
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${t.name} — Heap (bytes)"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ id = "q1", label = "Heap used", expression = "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }],
            [{ id = "q2", label = "Heap max", expression = "SELECT MAX(jvm_memory_heap_max) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${t.app_name}'${local.pg_filter[t.name]}" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${t.name} — GC time (ms/min)"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ id = "q1", label = "GC time ms/min", expression = "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }],
            [{ id = "q2", label = "GC cycles/min", yAxis = "right", expression = "SELECT SUM(jvm_gc_collections_count) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${t.name} — Threads & classes"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ id = "q1", label = "Threads", expression = "SELECT AVG(jvm_threads_count) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }],
            [{ id = "q2", label = "Classes loaded", yAxis = "right", expression = "SELECT AVG(jvm_classes_loaded) FROM \"CWAgent\" WHERE ${var.cwagent_dimension_key} = '${t.app_name}'${local.pg_filter[t.name]} GROUP BY InstanceId" }]
          ]
        }
      }
    ]
  ])
}

resource "aws_cloudwatch_dashboard" "jmx" {
  dashboard_name = "${var.project}-${var.env}-JVM"
  dashboard_body = jsonencode({ widgets = local.widgets })
}
