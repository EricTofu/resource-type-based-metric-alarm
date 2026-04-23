output "state_bucket" {
  description = "S3 bucket holding all Terraform state org-wide."
  value       = aws_s3_bucket.tfstate.id
}

output "state_kms_key_arn" {
  description = "KMS CMK ARN used for state SSE."
  value       = aws_kms_key.tfstate.arn
}

output "state_kms_key_alias" {
  description = "KMS alias. Use in downstream backend.hcl as kms_key_id."
  value       = aws_kms_alias.tfstate.name
}

output "tf_state_access_role_arn" {
  description = "Cross-account role ARN assumed by leaf backends for state I/O."
  value       = aws_iam_role.tf_state_access.arn
}

output "accounts" {
  description = "Alias -> {id, tf_deployer_role_arn} map consumed by every leaf via terraform_remote_state."
  value       = var.accounts
}
