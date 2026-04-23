variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of RDS/Aurora resources to monitor"
  type = list(object({
    name       = string
    enabled    = optional(bool, true)
    is_cluster = optional(bool, false)
    serverless = optional(bool, false)
    overrides = optional(object({
      severity                               = optional(string)
      description                            = optional(string)
      freeable_memory_threshold              = optional(number)
      freeable_memory_threshold_percent      = optional(number)
      cpu_threshold                          = optional(number)
      database_connections_threshold         = optional(number)
      database_connections_threshold_percent = optional(number)
      free_storage_threshold                 = optional(number)
      volume_bytes_used_threshold            = optional(number)
      acu_utilization_threshold              = optional(number)
      serverless_capacity_threshold          = optional(number)
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
      try(r.overrides.freeable_memory_threshold, null) == null || try(r.overrides.freeable_memory_threshold, 0) >= 0
    ])
    error_message = "overrides.freeable_memory_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.freeable_memory_threshold_percent, null) == null
      || (try(r.overrides.freeable_memory_threshold_percent, 0) >= 0 && try(r.overrides.freeable_memory_threshold_percent, 0) <= 100)
    ])
    error_message = "overrides.freeable_memory_threshold_percent must be between 0 and 100 inclusive, or omitted."
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
      try(r.overrides.database_connections_threshold, null) == null || try(r.overrides.database_connections_threshold, 0) >= 0
    ])
    error_message = "overrides.database_connections_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.database_connections_threshold_percent, null) == null
      || (try(r.overrides.database_connections_threshold_percent, 0) >= 0 && try(r.overrides.database_connections_threshold_percent, 0) <= 100)
    ])
    error_message = "overrides.database_connections_threshold_percent must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.free_storage_threshold, null) == null || try(r.overrides.free_storage_threshold, 0) >= 0
    ])
    error_message = "overrides.free_storage_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.volume_bytes_used_threshold, null) == null || try(r.overrides.volume_bytes_used_threshold, 0) >= 0
    ])
    error_message = "overrides.volume_bytes_used_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.acu_utilization_threshold, null) == null
      || (try(r.overrides.acu_utilization_threshold, 0) >= 0 && try(r.overrides.acu_utilization_threshold, 0) <= 100)
    ])
    error_message = "overrides.acu_utilization_threshold must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.serverless_capacity_threshold, null) == null || try(r.overrides.serverless_capacity_threshold, 0) >= 0
    ])
    error_message = "overrides.serverless_capacity_threshold must be non-negative or omitted."
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
  default     = 80
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

variable "default_volume_bytes_used_threshold" {
  description = "Default threshold for VolumeBytesUsed (bytes). Only applicable to Aurora clusters."
  type        = number
  default     = 107374182400 # 100GB
}

variable "default_acu_utilization_threshold" {
  description = "Default threshold for ACUUtilization"
  type        = number
  default     = 90
}

variable "default_serverless_capacity_threshold" {
  description = "Default threshold for ServerlessDatabaseCapacity"
  type        = number
  default     = 128
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
