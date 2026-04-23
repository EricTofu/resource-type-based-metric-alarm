output "alarm_arns" {
  description = "All alarm ARNs created by this stack, grouped by resource type."
  value = {
    alb          = try(module.alb_alarms[0].alarm_arns, {})
    apigateway   = try(module.apigateway_alarms[0].alarm_arns, {})
    ec2          = try(module.ec2_alarms[0].alarm_arns, {})
    asg          = try(module.asg_alarms[0].alarm_arns, {})
    lambda       = try(module.lambda_alarms[0].alarm_arns, {})
    rds          = try(module.rds_alarms[0].alarm_arns, {})
    s3           = try(module.s3_alarms[0].alarm_arns, {})
    elasticache  = try(module.elasticache_alarms[0].alarm_arns, {})
    opensearch   = try(module.opensearch_alarms[0].alarm_arns, {})
    ses          = try(module.ses_alarms[0].alarm_arns, {})
    cloudfront   = try(module.cloudfront_alarms[0].alarm_arns, {})
  }
}

output "alarm_names" {
  description = "All alarm names created by this stack, grouped by resource type."
  value = {
    alb          = try(module.alb_alarms[0].alarm_names, {})
    apigateway   = try(module.apigateway_alarms[0].alarm_names, {})
    ec2          = try(module.ec2_alarms[0].alarm_names, {})
    asg          = try(module.asg_alarms[0].alarm_names, {})
    lambda       = try(module.lambda_alarms[0].alarm_names, {})
    rds          = try(module.rds_alarms[0].alarm_names, {})
    s3           = try(module.s3_alarms[0].alarm_names, {})
    elasticache  = try(module.elasticache_alarms[0].alarm_names, {})
    opensearch   = try(module.opensearch_alarms[0].alarm_names, {})
    ses          = try(module.ses_alarms[0].alarm_names, {})
    cloudfront   = try(module.cloudfront_alarms[0].alarm_names, {})
  }
}
