variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of ASG resources to monitor"
  type = list(object({
    name             = string
    enabled          = optional(bool, true)
    desired_capacity = number
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
      disabled_alarms    = optional(set(string), [])
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
      try(r.overrides.capacity_threshold, null) == null || coalesce(try(r.overrides.capacity_threshold, null), 0) >= 0
    ])
    error_message = "overrides.capacity_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) :
        contains(["in_service_capacity"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: in_service_capacity"
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

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
