variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of Lambda resources to monitor"
  type = list(object({
    name       = string
    timeout_ms = number
    overrides = optional(object({
      severity              = optional(string)
      description           = optional(string)
      duration_threshold_ms = optional(number)
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

variable "concurrency_threshold" {
  description = "Threshold for ClaimedAccountConcurrency alarm"
  type        = number
  default     = 900
}
