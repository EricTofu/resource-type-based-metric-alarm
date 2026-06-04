variable "alias" {
  description = "Account alias (e.g., 'dev', 'stg', 'prod')."
  type        = string
}

variable "aws_region" {
  description = "Primary AWS region for this account."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to all resources in this stack."
  type        = map(string)
  default     = {}
}

variable "sns_choice" {
  description = "Whether to create new SNS topics ('create') or import existing ones ('import')."
  type        = string
  default     = "create"
}

variable "existing_sns_arns" {
  description = "Map of severity → existing SNS ARN (required when sns_choice = 'import')."
  type        = map(string)
  default     = {}
}

variable "ops_bucket" {
  description = "Name of the Ops Terraform state bucket."
  type        = string
}

variable "ops_state_role_arn" {
  description = "ARN of the tf-state-access role in the Ops account."
  type        = string
}