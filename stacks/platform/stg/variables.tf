variable "env" {
  description = "Environment / account tier this stack targets (e.g., dev)."
  type        = string
}

variable "aws_region" {
  description = "Primary AWS region."
  type        = string
}

variable "ops_state_bucket" {
  description = "Name of the Ops-account state bucket (same value for every leaf)."
  type        = string
}

variable "ops_state_role_arn" {
  description = "ARN of the Ops tf-state-access role (same value for every leaf)."
  type        = string
}

variable "sns_choice" {
  description = "create — provision new SNS topics; import — adopt existing topics."
  type        = string
  default     = "create"

  validation {
    condition     = contains(["create", "import"], var.sns_choice)
    error_message = "sns_choice must be \"create\" or \"import\"."
  }
}

variable "existing_sns_arns" {
  description = "Required when sns_choice = import. Map of severity -> existing SNS ARN in the primary region."
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  default = null

  validation {
    condition     = var.sns_choice != "import" || var.existing_sns_arns != null
    error_message = "existing_sns_arns is required when sns_choice = \"import\"."
  }
}

variable "existing_sns_arns_global" {
  description = "Required when sns_choice = import. Map of severity -> existing SNS ARN in us-east-1 — CloudWatch alarms can only notify same-region topics, and CloudFront alarms live in us-east-1, so the regional ARNs cannot be reused here."
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  default = null

  validation {
    condition     = var.sns_choice != "import" || var.existing_sns_arns_global != null
    error_message = "existing_sns_arns_global is required when sns_choice = \"import\"."
  }
  validation {
    condition = var.existing_sns_arns_global == null || alltrue([
      for k in ["WARN", "ERROR", "CRIT"] :
      can(regex("^arn:aws:sns:us-east-1:", var.existing_sns_arns_global[k]))
    ])
    error_message = "existing_sns_arns_global values must be us-east-1 SNS topic ARNs (arn:aws:sns:us-east-1:...)."
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
