locals {
  sns_topic_arns = var.sns_choice == "import" ? var.existing_sns_arns : {
    WARN  = aws_sns_topic.regional["WARN"].arn
    ERROR = aws_sns_topic.regional["ERROR"].arn
    CRIT  = aws_sns_topic.regional["CRIT"].arn
  }

  sns_topic_arns_global = var.sns_choice == "import" ? var.existing_sns_arns : {
    WARN  = aws_sns_topic.global["WARN"].arn
    ERROR = aws_sns_topic.global["ERROR"].arn
    CRIT  = aws_sns_topic.global["CRIT"].arn
  }
}

output "sns_topic_arns" {
  description = "Regional SNS topic ARNs by severity (WARN/ERROR/CRIT)."
  value       = local.sns_topic_arns
}

output "sns_topic_arns_global" {
  description = "us-east-1 SNS topic ARNs by severity — consumed by CloudFront alarms."
  value       = local.sns_topic_arns_global
}
