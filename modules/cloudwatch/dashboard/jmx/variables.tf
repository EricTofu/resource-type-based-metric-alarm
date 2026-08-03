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
    name                    = string
    cwagent_dimension_value = string
    process_group           = optional(string)
  }))
  validation {
    condition     = alltrue([for t in var.targets : try(trimspace(t.cwagent_dimension_value), "") != ""])
    error_message = "targets[*].cwagent_dimension_value must be a non-empty CWAgent dimension value."
  }
  validation {
    condition     = alltrue([for t in var.targets : try(trimspace(t.name), "") != ""])
    error_message = "targets[*].name must be a non-empty label (used in widget titles)."
  }
}

variable "cwagent_dimension_key" {
  description = "CloudWatch Agent *dimension* name carrying the fleet identity. Must equal the append_dimensions key in the agent config (cwagent/ec2-java/). This is NOT an AWS resource tag: no account setting enables it, and a mismatch returns zero series, which renders every widget empty. The asg module's tag-scoped key is separate; see \"Identity carriers\" in CLAUDE.md."
  type        = string
  default     = "AppName"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.cwagent_dimension_key))
    error_message = "cwagent_dimension_key must be letters, numbers or underscore only: anything else needs double-quoting inside the Metrics Insights expression, which this module does not do."
  }
}
