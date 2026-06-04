variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of Lambda resources to monitor"
  type = list(object({
    name       = string
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
