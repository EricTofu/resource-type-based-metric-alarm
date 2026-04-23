variable "service" {
  description = "Service name (e.g., 'billing'). Injected as project into every module call."
  type        = string
}

variable "alias" {
  description = "Account alias (e.g., 'dev', 'stg', 'prod')."
  type        = string
}

variable "aws_region" {
  description = "Primary AWS region for this account."
  type        = string
}

variable "ops_bucket" {
  description = "Name of the Ops Terraform state bucket."
  type        = string
}

variable "ops_state_role_arn" {
  description = "ARN of the tf-state-access role in the Ops account."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to every alarm in this stack."
  type        = map(string)
  default     = {}
}

variable "lambda_concurrency_threshold" {
  description = "Account-level concurrency alarm threshold."
  type        = number
  default     = 900
}

#------------------------------------------------------------------------------
# Resource lists — no project field; the stack injects project = var.service.
# Override field names must exactly match the library module's resources type.
#------------------------------------------------------------------------------

variable "alb_resources" {
  description = "ALB resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity                       = optional(string)
      description                    = optional(string)
      elb_5xx_threshold              = optional(number)
      target_5xx_threshold           = optional(number)
      unhealthy_host_threshold       = optional(number)
      target_response_time_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "apigateway_resources" {
  description = "API Gateway resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity            = optional(string)
      description         = optional(string)
      error_5xx_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "ec2_resources" {
  description = "EC2 resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "asg_resources" {
  description = "ASG resources to monitor."
  type = list(object({
    name             = string
    desired_capacity = number
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "lambda_resources" {
  description = "Lambda resources to monitor."
  type = list(object({
    name       = string
    timeout_ms = number
    overrides = optional(object({
      severity              = optional(string)
      description           = optional(string)
      duration_threshold_ms = optional(number)
    }), {})
  }))
  default = []
}

variable "rds_resources" {
  description = "RDS/Aurora resources to monitor."
  type = list(object({
    name       = string
    is_cluster = optional(bool, false)
    serverless = optional(bool, false)
    overrides = optional(object({
      severity                               = optional(string)
      description                            = optional(string)
      freeable_memory_threshold              = optional(number)
      freeable_memory_threshold_percent      = optional(number)
      cpu_threshold                          = optional(number)
      database_connections_threshold         = optional(number)
      database_connections_threshold_percent = optional(number)
      free_storage_threshold                 = optional(number)
      volume_bytes_used_threshold            = optional(number)
      acu_utilization_threshold              = optional(number)
      serverless_capacity_threshold          = optional(number)
    }), {})
  }))
  default = []
}

variable "s3_resources" {
  description = "S3 resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity            = optional(string)
      description         = optional(string)
      error_5xx_threshold = optional(number)
      replication_enabled = optional(bool)
    }), {})
  }))
  default = []
}

variable "elasticache_resources" {
  description = "ElastiCache resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "opensearch_resources" {
  description = "OpenSearch resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity                     = optional(string)
      description                  = optional(string)
      cpu_threshold                = optional(number)
      jvm_memory_threshold         = optional(number)
      old_gen_jvm_memory_threshold = optional(number)
      free_storage_threshold       = optional(number)
    }), {})
  }))
  default = []
}

variable "ses_resources" {
  description = "SES resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity              = optional(string)
      description           = optional(string)
      bounce_rate_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "cloudfront_resources" {
  description = "CloudFront distributions to monitor."
  type = list(object({
    distribution_id = string
    overrides = optional(object({
      severity                 = optional(string)
      description              = optional(string)
      error_4xx_threshold      = optional(number)
      error_5xx_threshold      = optional(number)
      origin_latency_threshold = optional(number)
      cache_hit_rate_threshold = optional(number)
    }), {})
  }))
  default = []
}
