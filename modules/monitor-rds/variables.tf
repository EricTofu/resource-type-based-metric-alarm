variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of RDS/Aurora resources to monitor"
  type = list(object({
    name       = string
    is_cluster = optional(bool, false)
    overrides = optional(object({
      severity                               = optional(string)
      description                            = optional(string)
      freeable_memory_threshold              = optional(number)
      freeable_memory_threshold_percent      = optional(number)
      cpu_threshold                          = optional(number)
      database_connections_threshold         = optional(number)
      database_connections_threshold_percent = optional(number)
      free_storage_threshold                 = optional(number)
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

variable "default_freeable_memory_threshold" {
  description = "Default threshold for FreeableMemory (bytes). Only used if percentage calculation is disabled or fails."
  type        = number
  default     = 1073741824 # 1GB
}

variable "default_freeable_memory_threshold_percent" {
  description = "Default threshold for FreeableMemory as a percentage of total RAM (e.g., 10 for 10%)"
  type        = number
  default     = 10
}

variable "default_cpu_threshold" {
  description = "Default threshold for CPUUtilization"
  type        = number
  default     = 90
}

variable "default_database_connections_threshold" {
  description = "Default threshold for DatabaseConnections"
  type        = number
  default     = 2700
}

variable "default_database_connections_threshold_percent" {
  description = "Default database connections threshold percentage (if not overridden per resource)"
  type        = number
  default     = 80
}

variable "default_free_storage_threshold" {
  description = "Default threshold for FreeStorageSpace (bytes)"
  type        = number
  default     = 10737418240 # 10GB
}
