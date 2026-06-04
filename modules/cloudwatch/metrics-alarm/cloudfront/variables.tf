variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of CloudFront distributions to monitor"
  type = list(object({
    distribution_id = string
    name            = optional(string) # Friendly name for alarm naming
    overrides = optional(object({
      severity                 = optional(string)
      description              = optional(string)
      error_4xx_threshold      = optional(number)
      error_5xx_threshold      = optional(number)
      origin_latency_threshold = optional(number)
      cache_hit_rate_threshold = optional(number)
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
  description = "SNS topic ARNs mapped by severity (must be in us-east-1)"
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

variable "default_error_4xx_threshold" {
  description = "Default threshold for 4xxErrorRate (%)"
  type        = number
  default     = 5
}

variable "default_error_5xx_threshold" {
  description = "Default threshold for 5xxErrorRate (%)"
  type        = number
  default     = 1
}

variable "default_origin_latency_threshold" {
  description = "Default threshold for OriginLatency (seconds)"
  type        = number
  default     = 5
}

variable "default_cache_hit_rate_threshold" {
  description = "Default threshold for CacheHitRate (%, alarm when below)"
  type        = number
  default     = 80
}
