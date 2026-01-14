variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of SES resources to monitor"
  type = list(object({
    name = string
    overrides = optional(object({
      severity              = optional(string)
      description           = optional(string)
      bounce_rate_threshold = optional(number)
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

variable "default_bounce_rate_threshold" {
  description = "Default threshold for Reputation.BounceRate"
  type        = number
  default     = 0.03
}
