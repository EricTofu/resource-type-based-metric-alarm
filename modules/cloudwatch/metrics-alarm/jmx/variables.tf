variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "Java host groups to monitor, identified by the CWAgent AppName dimension (see cwagent/ec2-java/). One entry may cover several instances — ASG fleet members, or interchangeable standalone hosts sharing an AppName — because alarms fan out per InstanceId at evaluation time. `name` is a label for alarm naming and output keys only; it is NOT a Name-tag lookup. One entry covers one JVM per host: app_name is validated unique across entries, so a host running a second JVM cannot be given an entry of its own, and process_group narrows an existing entry's queries rather than permitting an additional entry under the same app_name."
  type = list(object({
    name           = string
    app_name       = string
    heap_max_bytes = optional(number)
    process_group  = optional(string)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      heap_threshold  = optional(number)
      disabled_alarms = optional(set(string), [])
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
  # gc_time was removed 2026-07-31 (PutMetricAlarm rejects DIFF over a
  # multi-series query — see main.tf). It is deliberately NOT accepted here:
  # a leftover `disabled_alarms: [gc_time]` fails the plan with this message
  # rather than being silently tolerated for an alarm that no longer exists.
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) : contains(["heap_used"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: heap_used. (gc_time was removed — PutMetricAlarm cannot back an alarm with DIFF over a GROUP BY query; drop the entry.)"
  }
  # try(...,"") makes null fail: app_name is the identity and cannot be inferred.
  validation {
    condition     = alltrue([for r in var.resources : try(trimspace(r.app_name), "") != ""])
    error_message = "app_name must be a non-empty string — the CWAgent AppName dimension value that identifies this host group."
  }
  validation {
    condition     = length([for r in var.resources : r.app_name]) == length(distinct([for r in var.resources : r.app_name]))
    error_message = "app_name values must be unique across entries (one AppName = one host group)."
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
  description = "Default JVM heap threshold as a percent of each entry's heap_max_bytes. Rendered into a byte threshold on jvm_memory_heap_used."
  type        = number
  default     = 85
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
