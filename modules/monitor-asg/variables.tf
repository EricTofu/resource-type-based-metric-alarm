variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of ASG resources to monitor"
  type = list(object({
    name             = string
    desired_capacity = number
    overrides = optional(object({
      severity    = optional(string)
      description = optional(string)
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
