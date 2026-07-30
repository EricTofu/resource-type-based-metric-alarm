module "alb_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/alb"
  count  = length(var.alb_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.alb_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "apigateway_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/apigateway"
  count  = length(var.apigateway_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.apigateway_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "ec2_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/ec2"
  count  = length(var.ec2_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.ec2_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "asg_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/asg"
  count  = length(var.asg_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.asg_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "lambda_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/lambda"
  count  = length(var.lambda_resources) > 0 ? 1 : 0

  project                   = var.project
  env                       = var.env
  resources                 = var.lambda_resources
  sns_topic_arns            = local.sns_topic_arns
  common_tags               = var.common_tags
  concurrency_threshold     = var.lambda_concurrency_threshold
  concurrency_alarm_enabled = var.lambda_concurrency_alarm_enabled
}

module "rds_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/rds"
  count  = length(var.rds_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.rds_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "s3_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/s3"
  count  = length(var.s3_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.s3_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "elasticache_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/elasticache"
  count  = length(var.elasticache_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.elasticache_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "opensearch_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/opensearch"
  count  = length(var.opensearch_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.opensearch_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "ses_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/ses"
  count  = length(var.ses_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.ses_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "cloudfront_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/cloudfront"
  count  = length(var.cloudfront_resources) > 0 ? 1 : 0
  providers = {
    aws = aws.us_east_1
  }

  project        = var.project
  env            = var.env
  resources      = var.cloudfront_resources
  sns_topic_arns = local.sns_topic_arns_global
  common_tags    = var.common_tags
}

module "efs_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/efs"
  count  = length(var.efs_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.efs_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "jmx_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/jmx"
  count  = length(var.jmx_resources) > 0 ? 1 : 0

  project        = var.project
  env            = var.env
  resources      = var.jmx_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}

module "jmx_dashboard" {
  source = "../../../../modules/cloudwatch/dashboard/jmx"
  count  = var.jmx_dashboard_enabled && length(var.jmx_resources) > 0 ? 1 : 0

  project = var.project
  env     = var.env
  region  = var.aws_region
  targets = module.jmx_alarms[0].dashboard_targets
}
