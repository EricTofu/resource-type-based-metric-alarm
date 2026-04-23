variable "aws_region" {
  description = "Primary AWS region for state bucket and KMS CMK."
  type        = string
}

variable "bootstrap_profile" {
  description = "AWS CLI profile with admin access to the Ops account. Used only to bootstrap this stack."
  type        = string
}

variable "ops_account_id" {
  description = "12-digit Ops account ID (holds the state bucket and CMK)."
  type        = string
}

variable "caller_principal_arn" {
  description = "ARN of the human/CI identity that will run Terraform (used in trust policies)."
  type        = string
}

variable "accounts" {
  description = "Map of account alias → { id, tf_deployer_role_arn } for every target account."
  type = map(object({
    id                 = string
    tf_deployer_role_arn = string
  }))
}

variable "common_tags" {
  description = "Tags applied to all resources in this stack."
  type        = map(string)
  default     = {}
}

variable "org" {
  description = "Short slug used in the state bucket name."
  type        = string
}