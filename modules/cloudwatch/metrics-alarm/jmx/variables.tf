variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "Java host groups to monitor, identified by the CloudWatch Agent dimension named by cwagent_dimension_key (see cwagent/ec2-java/). One entry may cover several instances — ASG fleet members, or interchangeable standalone hosts sharing an identity — because alarms fan out per InstanceId at evaluation time. `name` is a label for alarm naming and output keys only; it is NOT a Name-tag lookup. This module is CWAgent-only, so there is no tag value here; an ASG fleet entry pairs with this one by carrying the same cwagent_dimension_value. One entry covers one JVM per host: cwagent_dimension_value is validated unique across entries, so a host running a second JVM cannot be given an entry of its own, and process_group narrows an existing entry's queries rather than permitting an additional entry under the same identity."
  type = list(object({
    name                    = string
    cwagent_dimension_value = string
    heap_max_bytes          = optional(number)
    process_group           = optional(string)
    enabled                 = optional(bool, true)
    overrides = optional(object({
      severity                = optional(string)
      description             = optional(string)
      heap_threshold          = optional(number)
      heap_evaluation_periods = optional(number)
      gc_time_threshold_ms    = optional(number)
      disabled_alarms         = optional(set(string), [])
    }), {})
  }))
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.severity, null) == null
      || try(contains(["WARN", "ERROR", "CRIT"], r.overrides.severity), false)
    ])
    error_message = "overrides.severity must be one of WARN, ERROR, CRIT (case-sensitive) or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.heap_threshold, null) == null
      || (coalesce(try(r.overrides.heap_threshold, null), 0) >= 0 && coalesce(try(r.overrides.heap_threshold, null), 0) <= 100)
    ])
    error_message = "overrides.heap_threshold must be between 0 and 100 inclusive, or omitted. It is a percentage of heap_max_bytes."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.gc_time_threshold_ms, null) == null
      || coalesce(try(r.overrides.gc_time_threshold_ms, null), 0) >= 0
    ])
    error_message = "overrides.gc_time_threshold_ms must be >= 0, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.heap_evaluation_periods, null) == null
      || coalesce(try(r.overrides.heap_evaluation_periods, null), 0) >= 1
    ])
    error_message = "overrides.heap_evaluation_periods must be >= 1, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) : contains(["heap_used", "gc_time"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: heap_used, gc_time"
  }
  # try(...,"") makes null fail: this is the identity and cannot be inferred.
  validation {
    condition     = alltrue([for r in var.resources : try(trimspace(r.cwagent_dimension_value), "") != ""])
    error_message = "cwagent_dimension_value must be a non-empty string — the CWAgent dimension value that identifies this host group."
  }
  validation {
    condition     = length([for r in var.resources : r.cwagent_dimension_value]) == length(distinct([for r in var.resources : r.cwagent_dimension_value]))
    error_message = "cwagent_dimension_value must be unique across entries (one identity = one host group)."
  }
  # try(...,"-") makes null pass: process_group is optional.
  validation {
    condition     = alltrue([for r in var.resources : try(trimspace(r.process_group), "-") != ""])
    error_message = "process_group must be a non-empty string when set, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      contains(try(r.overrides.disabled_alarms, []), "heap_used")
      || (r.heap_max_bytes != null && coalesce(r.heap_max_bytes, 0) > 0)
    ])
    error_message = "heap_max_bytes (> 0, the JVM -Xmx in bytes) is required unless heap_used is in disabled_alarms — the heap alarm is a byte threshold, because CloudWatch math cannot divide two GROUP BY series arrays."
  }
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs mapped by severity"
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  validation {
    condition     = alltrue([for k in ["WARN", "ERROR", "CRIT"] : can(regex("^arn:aws:sns:", var.sns_topic_arns[k]))])
    error_message = "sns_topic_arns values must be SNS ARNs (starting with arn:aws:sns:)."
  }
}

variable "default_heap_threshold" {
  description = "Default JVM heap threshold as a percent of each entry's heap_max_bytes. Rendered into a byte threshold on jvm_memory_heap_used. 90 rather than 85 because the alarm now requires a long sustained window: a healthy JVM peaks near -Xmx just before a collection, so only a heap that STAYS high indicates a live set that does not fit."
  type        = number
  default     = 90
}

variable "default_heap_evaluation_periods" {
  description = "Consecutive 60s periods jvm_memory_heap_used must exceed the threshold before the heap alarm fires. Long by design (10 = 10 minutes): duration substitutes for the post-GC sampling CloudWatch cannot do. datapoints_to_alarm is always set equal to this."
  type        = number
  default     = 10
}

variable "default_gc_time_threshold_ms" {
  description = "Default threshold in milliseconds of GC per minute. 6000 = 10% of wall clock in GC, the standard GC-overhead heuristic. Assumes the agent's metrics_collection_interval is 60 — the metric is a per-interval delta."
  type        = number
  default     = 6000
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}

variable "cwagent_dimension_key" {
  description = "CloudWatch Agent *dimension* name carrying the fleet identity. Must equal the append_dimensions key in the agent config (cwagent/ec2-java/). This is NOT an AWS resource tag: no account setting enables it, and a mismatch returns zero series, which these alarms treat as not breaching — i.e. silently green. The asg module's tag-scoped key is separate; see \"Identity carriers\" in CLAUDE.md."
  type        = string
  default     = "AppName"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.cwagent_dimension_key))
    error_message = "cwagent_dimension_key must be letters, numbers or underscore only: anything else needs double-quoting inside the Metrics Insights expression, which this module does not do."
  }
}
