variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of ALB resources to monitor"
  type = list(object({
    name    = string
    enabled = optional(bool, true)
    overrides = optional(object({
      severity                       = optional(string)
      description                    = optional(string)
      elb_5xx_threshold              = optional(number)
      target_5xx_threshold           = optional(number)
      unhealthy_host_threshold       = optional(number)
      target_response_time_threshold = optional(number)
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
      try(r.overrides.elb_5xx_threshold, null) == null || try(r.overrides.elb_5xx_threshold, 0) >= 0
    ])
    error_message = "overrides.elb_5xx_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.target_5xx_threshold, null) == null || try(r.overrides.target_5xx_threshold, 0) >= 0
    ])
    error_message = "overrides.target_5xx_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.unhealthy_host_threshold, null) == null || try(r.overrides.unhealthy_host_threshold, 0) >= 0
    ])
    error_message = "overrides.unhealthy_host_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.target_response_time_threshold, null) == null || try(r.overrides.target_response_time_threshold, 0) >= 0
    ])
    error_message = "overrides.target_response_time_threshold must be non-negative or omitted."
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

variable "default_elb_5xx_threshold" {
  description = "Default threshold for HTTPCode_ELB_5XX_Count"
  type        = number
  default     = 5
}

variable "default_target_5xx_threshold" {
  description = "Default threshold for HTTPCode_Target_5XX_Count"
  type        = number
  default     = 5
}

variable "default_unhealthy_host_threshold" {
  description = "Default threshold for UnHealthyHostCount"
  type        = number
  default     = 1
}

variable "default_target_response_time_threshold" {
  description = "Default threshold for TargetResponseTime (p90)"
  type        = number
  default     = 20
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
