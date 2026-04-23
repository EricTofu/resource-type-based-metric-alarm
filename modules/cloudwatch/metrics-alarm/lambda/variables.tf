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
    }), {})
  }))
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.severity, null) == null
      || contains(["WARN", "ERROR", "CRIT"], r.overrides.severity)
    ])
    error_message = "overrides.severity must be one of WARN, ERROR, CRIT (case-sensitive) or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.duration_threshold_ms, null) == null || try(r.overrides.duration_threshold_ms, 0) >= 0
    ])
    error_message = "overrides.duration_threshold_ms must be non-negative or omitted."
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

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
