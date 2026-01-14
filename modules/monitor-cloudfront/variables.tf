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
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs mapped by severity (must be in us-east-1)"
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
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
