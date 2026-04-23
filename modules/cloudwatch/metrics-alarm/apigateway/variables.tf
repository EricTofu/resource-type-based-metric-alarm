variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of API Gateway resources to monitor"
  type = list(object({
    name = string
    overrides = optional(object({
      severity            = optional(string)
      description         = optional(string)
      error_5xx_threshold = optional(number)
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

variable "default_5xx_error_threshold" {
  description = "Default threshold for 5XXError rate"
  type        = number
  default     = 0.05
}
