variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of EC2 resources to monitor"
  type = list(object({
    name = string
    enabled = optional(bool, true)
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
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
      try(r.overrides.cpu_threshold, null) == null
      || (try(r.overrides.cpu_threshold, 0) >= 0 && try(r.overrides.cpu_threshold, 0) <= 100)
    ])
    error_message = "overrides.cpu_threshold must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.memory_threshold, null) == null
      || (try(r.overrides.memory_threshold, 0) >= 0 && try(r.overrides.memory_threshold, 0) <= 100)
    ])
    error_message = "overrides.memory_threshold must be between 0 and 100 inclusive, or omitted."
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

#------------------------------------------------------------------------------
# Default Thresholds
#------------------------------------------------------------------------------

variable "default_cpu_threshold" {
  description = "Default threshold for CPUUtilization"
  type        = number
  default     = 80
}

variable "default_memory_threshold" {
  description = "Default threshold for mem_used_percent"
  type        = number
  default     = 80
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
