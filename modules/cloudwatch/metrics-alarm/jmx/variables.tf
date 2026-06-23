variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of EC2 hosts (by Name tag) running a JMX-exposed Java app"
  type = list(object({
    name    = string
    enabled = optional(bool, true)
    overrides = optional(object({
      severity             = optional(string)
      description          = optional(string)
      heap_threshold       = optional(number)
      gc_time_threshold_ms = optional(number)
      disabled_alarms      = optional(set(string), [])
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
    error_message = "overrides.heap_threshold must be between 0 and 100 inclusive, or omitted."
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
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) : contains(["heap_used", "gc_time"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: heap_used, gc_time"
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
  description = "Default threshold (percent) for JVM heap used"
  type        = number
  default     = 85
}

variable "default_gc_time_threshold_ms" {
  description = "Default threshold (milliseconds of GC per minute) for jvm.gc.collections.elapsed"
  type        = number
  default     = 6000
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
