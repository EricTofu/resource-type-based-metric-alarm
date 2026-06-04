variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of OpenSearch resources to monitor"
  type = list(object({
    name = string
    overrides = optional(object({
      severity                     = optional(string)
      description                  = optional(string)
      cpu_threshold                = optional(number)
      jvm_memory_threshold         = optional(number)
      old_gen_jvm_memory_threshold = optional(number)
      free_storage_threshold       = optional(number)
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

#------------------------------------------------------------------------------
# Default Thresholds
#------------------------------------------------------------------------------

variable "default_cpu_threshold" {
  description = "Default threshold for CPUUtilization"
  type        = number
  default     = 80
}

variable "default_jvm_memory_threshold" {
  description = "Default threshold for JVMMemoryPressure"
  type        = number
  default     = 95
}

variable "default_old_gen_jvm_memory_threshold" {
  description = "Default threshold for OldGenJVMMemoryPressure"
  type        = number
  default     = 95
}

variable "default_free_storage_threshold" {
  description = "Default threshold for FreeStorageSpace (MB)"
  type        = number
  default     = 20480 # 20GB
}
