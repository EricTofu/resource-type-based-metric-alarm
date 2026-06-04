output "state_bucket" {
  description = "Name of the Terraform state S3 bucket."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state S3 bucket."
  value       = aws_s3_bucket.tfstate.arn
}

output "state_kms_key_arn" {
  description = "ARN of the KMS CMK used for state encryption."
  value       = aws_kms_key.tfstate.arn
}

output "state_kms_alias" {
  description = "Alias of the KMS CMK used for state encryption."
  value       = aws_kms_alias.tfstate.name
}

output "tf_state_access_role_arn" {
  description = "ARN of the cross-account state access IAM role."
  value       = aws_iam_role.tf_state_access.arn
}

output "accounts" {
  description = "Map of account alias → { id, tf_deployer_role_arn } for downstream stacks to reference."
  value       = var.accounts
}

output "org" {
  description = "Organization slug used in resource naming."
  value       = var.org
}