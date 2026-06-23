#------------------------------------------------------------------------------
# JVM / JMX CloudWatch dashboard. Body built with jsonencode (single source);
# `dashboard_json` output is the same body for console import (dashboards/jmx-jvm.json).
# Three widgets per instance: heap (used % + bytes), GC time/min, threads + classes.
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
  widgets = flatten([
    for idx, inst in var.instances : [
      {
        type   = "metric"
        x      = 0
        y      = idx * 6
        width  = 8
        height = 6
        properties = {
          title  = "${inst.name} — Heap"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ expression = "100*m1/m2", label = "Heap used %", id = "e1" }],
            ["CWAgent", "jvm.memory.heap.used", "InstanceId", inst.instance_id, { id = "m1", visible = false }],
            ["CWAgent", "jvm.memory.heap.max", "InstanceId", inst.instance_id, { id = "m2", visible = false }],
            ["CWAgent", "jvm.memory.heap.committed", "InstanceId", inst.instance_id, { label = "Heap committed (bytes)", yAxis = "right" }]
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
          title  = "${inst.name} — GC time (ms/min)"
          region = var.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            [{ expression = "DIFF(m1)", label = "GC time ms/min", id = "e1" }],
            ["CWAgent", "jvm.gc.collections.elapsed", "InstanceId", inst.instance_id, { id = "m1", stat = "Maximum", visible = false }],
            [{ expression = "DIFF(m2)", label = "GC cycles/min", id = "e2", yAxis = "right" }],
            ["CWAgent", "jvm.gc.collections.count", "InstanceId", inst.instance_id, { id = "m2", stat = "Maximum", visible = false }]
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
          title  = "${inst.name} — Threads & classes"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            ["CWAgent", "jvm.threads.count", "InstanceId", inst.instance_id, { label = "Threads" }],
            ["CWAgent", "jvm.classes.loaded", "InstanceId", inst.instance_id, { label = "Classes loaded", yAxis = "right" }]
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
