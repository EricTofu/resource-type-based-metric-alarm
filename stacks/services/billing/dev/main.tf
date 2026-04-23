#------------------------------------------------------------------------------
# ALB Monitoring
#------------------------------------------------------------------------------

module "alb_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/alb"
  count  = length(var.alb_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.alb_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# API Gateway Monitoring
#------------------------------------------------------------------------------

module "apigateway_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/apigateway"
  count  = length(var.apigateway_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.apigateway_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# EC2 Monitoring
#------------------------------------------------------------------------------

module "ec2_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/ec2"
  count  = length(var.ec2_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.ec2_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# ASG Monitoring
#------------------------------------------------------------------------------

module "asg_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/asg"
  count  = length(var.asg_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.asg_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# Lambda Monitoring
#------------------------------------------------------------------------------

module "lambda_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/lambda"
  count  = length(var.lambda_resources) > 0 ? 1 : 0

  project               = local.project
  resources             = var.lambda_resources
  sns_topic_arns        = local.sns_topic_arns
  concurrency_threshold = var.lambda_concurrency_threshold
}

#------------------------------------------------------------------------------
# RDS Monitoring
#------------------------------------------------------------------------------

module "rds_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/rds"
  count  = length(var.rds_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.rds_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# S3 Monitoring
#------------------------------------------------------------------------------

module "s3_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/s3"
  count  = length(var.s3_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.s3_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# ElastiCache Monitoring
#------------------------------------------------------------------------------

module "elasticache_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/elasticache"
  count  = length(var.elasticache_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.elasticache_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# OpenSearch Monitoring
#------------------------------------------------------------------------------

module "opensearch_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/opensearch"
  count  = length(var.opensearch_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.opensearch_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# SES Monitoring
#------------------------------------------------------------------------------

module "ses_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/ses"
  count  = length(var.ses_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.ses_resources
  sns_topic_arns = local.sns_topic_arns
}

#------------------------------------------------------------------------------
# CloudFront Monitoring (Global - us-east-1)
#------------------------------------------------------------------------------

module "cloudfront_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/cloudfront"
  count  = length(var.cloudfront_resources) > 0 ? 1 : 0
  providers = {
    aws = aws.us_east_1
  }

  project        = local.project
  resources      = var.cloudfront_resources
  sns_topic_arns = local.sns_topic_arns_global
}