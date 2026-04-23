variable "alias" {
  description = "Account alias this stack targets (e.g., account-dev)."
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
  description = "Required when sns_choice = import. Map of severity -> existing SNS ARN."
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  default = null
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
