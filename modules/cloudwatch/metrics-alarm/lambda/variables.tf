variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of Lambda resources to monitor"
  type = list(object({
    name       = string
    enabled    = optional(bool, true)
    timeout_ms = number
    overrides = optional(object({
      severity              = optional(string)
      description           = optional(string)
      duration_threshold_ms = optional(number)
      disabled_alarms       = optional(set(string), [])
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
      try(r.overrides.duration_threshold_ms, null) == null || coalesce(try(r.overrides.duration_threshold_ms, null), 0) >= 0
    ])
    error_message = "overrides.duration_threshold_ms must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) :
        contains(["duration"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: duration"
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
    condition = alltrue([
      for k in ["WARN", "ERROR", "CRIT"] :
      can(regex("^arn:aws:sns:", var.sns_topic_arns[k]))
    ])
    error_message = "sns_topic_arns values must be SNS ARNs (starting with arn:aws:sns:)."
  }

}

variable "concurrency_threshold" {
  description = "Threshold for ClaimedAccountConcurrency alarm"
  type        = number
  default     = 900
}

variable "concurrency_alarm_enabled" {
  description = "Whether to create the account-level ClaimedAccountConcurrency alarm."
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
