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
