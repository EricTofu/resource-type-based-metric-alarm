variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of EC2 resources to monitor"
  type = list(object({
    name = string
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
    }), {})
  }))
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs mapped by severity"
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
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
