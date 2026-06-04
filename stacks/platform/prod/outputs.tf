output "sns_topic_arns" {
  description = "Map of severity → regional SNS topic ARN."
  value       = local.sns_topic_arns
}

output "sns_topic_arns_global" {
  description = "Map of severity → global (us-east-1) SNS topic ARN for CloudFront."
  value       = local.sns_topic_arns_global
}

output "alias" {
  description = "Account alias."
  value       = var.alias
}