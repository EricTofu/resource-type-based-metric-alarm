variable "project" {
  description = "Project name for dashboard naming"
  type        = string
}

variable "env" {
  description = "Environment name for dashboard naming"
  type        = string
}

variable "region" {
  description = "Region the JVM metrics live in (widget region)"
  type        = string
}

variable "targets" {
  description = "Java host groups to chart, identified by the CWAgent AppName dimension. Widgets use Metrics Insights grouped by InstanceId, so membership resolves at render time — no instance IDs, and fleet churn needs no apply. Pass modules/cloudwatch/metrics-alarm/jmx's dashboard_targets output."
  type = list(object({
    name          = string
    app_name      = string
    process_group = optional(string)
  }))
  validation {
    condition     = alltrue([for t in var.targets : try(trimspace(t.app_name), "") != ""])
    error_message = "targets[*].app_name must be a non-empty CWAgent AppName dimension value."
  }
  validation {
    condition     = alltrue([for t in var.targets : try(trimspace(t.name), "") != ""])
    error_message = "targets[*].name must be a non-empty label (used in widget titles)."
  }
}
