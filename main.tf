#------------------------------------------------------------------------------
# ALB Monitoring
#------------------------------------------------------------------------------

module "monitor_alb" {
  source = "./modules/monitor-alb"

  for_each = { for idx, group in var.alb_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# API Gateway Monitoring
#------------------------------------------------------------------------------

module "monitor_apigateway" {
  source = "./modules/monitor-apigateway"

  for_each = { for idx, group in var.apigateway_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# EC2 Monitoring
#------------------------------------------------------------------------------

module "monitor_ec2" {
  source = "./modules/monitor-ec2"

  for_each = { for idx, group in var.ec2_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# ASG Monitoring
#------------------------------------------------------------------------------

module "monitor_asg" {
  source = "./modules/monitor-asg"

  for_each = { for idx, group in var.asg_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# Lambda Monitoring
#------------------------------------------------------------------------------

module "monitor_lambda" {
  source = "./modules/monitor-lambda"

  for_each = { for idx, group in var.lambda_resources : "${group.project}" => group }

  project               = each.value.project
  resources             = each.value.resources
  sns_topic_arns        = var.sns_topic_arns
  concurrency_threshold = var.lambda_concurrency_threshold
}

#------------------------------------------------------------------------------
# RDS Monitoring
#------------------------------------------------------------------------------

module "monitor_rds" {
  source = "./modules/monitor-rds"

  for_each = { for idx, group in var.rds_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# S3 Monitoring
#------------------------------------------------------------------------------

module "monitor_s3" {
  source = "./modules/monitor-s3"

  for_each = { for idx, group in var.s3_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# ElastiCache Monitoring
#------------------------------------------------------------------------------

module "monitor_elasticache" {
  source = "./modules/monitor-elasticache"

  for_each = { for idx, group in var.elasticache_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# OpenSearch Monitoring
#------------------------------------------------------------------------------

module "monitor_opensearch" {
  source = "./modules/monitor-opensearch"

  for_each = { for idx, group in var.opensearch_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# SES Monitoring
#------------------------------------------------------------------------------

module "monitor_ses" {
  source = "./modules/monitor-ses"

  for_each = { for idx, group in var.ses_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns
}

#------------------------------------------------------------------------------
# CloudFront Monitoring (Global - us-east-1)
#------------------------------------------------------------------------------

module "monitor_cloudfront" {
  source = "./modules/monitor-cloudfront"
  providers = {
    aws = aws.us_east_1
  }

  for_each = { for idx, group in var.cloudfront_resources : "${group.project}" => group }

  project        = each.value.project
  resources      = each.value.resources
  sns_topic_arns = var.sns_topic_arns_global
}
