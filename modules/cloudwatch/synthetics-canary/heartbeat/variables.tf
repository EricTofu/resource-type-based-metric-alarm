variable "project" {
  description = "Service name — used in canary names and tags."
  type        = string
}

variable "resources" {
  description = "List of URLs to canary-check. Each entry produces one canary resource + one SuccessPercent alarm."
  type = list(object({
    name              = string
    url               = string
    frequency_minutes = optional(number, 5)
    timeout_seconds   = optional(number, 30)
    overrides = optional(object({
      severity                  = optional(string)
      description               = optional(string)
      success_percent_threshold = optional(number)
    }), {})
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.severity, null) == null
      || contains(["WARN", "ERROR", "CRIT"], r.overrides.severity)
    ])
    error_message = "overrides.severity must be one of WARN, ERROR, CRIT or omitted."
  }

  validation {
    condition = alltrue([for r in var.resources : can(regex("^https?://", r.url))])
    error_message = "Each resources[].url must start with http:// or https://"
  }
}

variable "sns_topic_arns" {
  description = "Map severity → SNS ARN. Same shape as metrics-alarm modules."
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

variable "artifacts_bucket" {
  description = "S3 bucket that Synthetics uses to store run artifacts. Must already exist in the target account."
  type        = string
}

variable "execution_role_arn" {
  description = "IAM role assumed by the canary. Must already exist with the standard CloudWatchSyntheticsRole policy."
  type        = string
}

variable "default_success_percent_threshold" {
  description = "Alarm triggers when SuccessPercent over the last evaluation window drops below this value."
  type        = number
  default     = 90
}

variable "common_tags" {
  description = "Tags merged into every canary and alarm."
  type        = map(string)
  default     = {}
}