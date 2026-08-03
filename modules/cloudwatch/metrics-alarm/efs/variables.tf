variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of EFS file systems to monitor"
  type = list(object({
    file_system_id = string
    name           = optional(string)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity                  = optional(string)
      description               = optional(string)
      throughput_util_threshold = optional(number)
      period                    = optional(number)
      evaluation_periods        = optional(number)
      disabled_alarms           = optional(set(string), [])
    }), {})
  }))
  validation {
    condition     = alltrue([for r in var.resources : can(regex("^fs-", r.file_system_id))])
    error_message = "file_system_id must be an EFS file system id starting with 'fs-'."
  }
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
      try(r.overrides.throughput_util_threshold, null) == null
      || (coalesce(try(r.overrides.throughput_util_threshold, null), 0) >= 0 && coalesce(try(r.overrides.throughput_util_threshold, null), 0) <= 100)
    ])
    error_message = "overrides.throughput_util_threshold must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) : contains(["throughput_util"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: throughput_util"
  }
  validation {
    condition     = length(distinct([for r in var.resources : coalesce(r.name, r.file_system_id)])) == length(var.resources)
    error_message = "coalesce(name, file_system_id) must be unique across resources — duplicate friendly names make two entries render the same alarm_name, and CloudWatch upserts by name (one file system would be silently unmonitored)."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.period, null) == null
      || (coalesce(try(r.overrides.period, null), 3600) >= 60 && coalesce(try(r.overrides.period, null), 3600) % 60 == 0)
    ])
    error_message = "overrides.period must be a multiple of 60 seconds (>= 60), or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      coalesce(try(r.overrides.evaluation_periods, null), 6) >= 1
      && coalesce(try(r.overrides.period, null), 3600) * coalesce(try(r.overrides.evaluation_periods, null), 6) <= 86400
    ])
    error_message = "overrides.evaluation_periods must be >= 1, and period * evaluation_periods must not exceed 86400 seconds (CloudWatch's one-day evaluation-interval limit)."
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
    condition     = alltrue([for k in ["WARN", "ERROR", "CRIT"] : can(regex("^arn:aws:sns:", var.sns_topic_arns[k]))])
    error_message = "sns_topic_arns values must be SNS ARNs (starting with arn:aws:sns:)."
  }
}

variable "default_throughput_util_threshold" {
  description = "Default threshold (percent) for EFS throughput utilization"
  type        = number
  default     = 80
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
