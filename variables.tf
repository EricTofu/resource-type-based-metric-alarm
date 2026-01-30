#------------------------------------------------------------------------------
# General Configuration
#------------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "AWS profile"
  type        = string
  default     = "default"
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs for alarm actions, mapped by severity level"
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
}

variable "sns_topic_arns_global" {
  description = "SNS topic ARNs for global resources (us-east-1), mapped by severity level. Required if monitoring CloudFront."
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  default = null
}

variable "default_severity" {
  description = "Default severity level for alarms (WARN, ERROR, CRIT)"
  type        = string
  default     = "WARN"
}

#------------------------------------------------------------------------------
# ALB Resources
#------------------------------------------------------------------------------

variable "alb_resources" {
  description = "List of ALB resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
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
  }))
  default = []
}

#------------------------------------------------------------------------------
# API Gateway Resources
#------------------------------------------------------------------------------

variable "apigateway_resources" {
  description = "List of API Gateway resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
      name = string
      overrides = optional(object({
        severity            = optional(string)
        description         = optional(string)
        error_5xx_threshold = optional(number)
      }), {})
    }))
  }))
  default = []
}

#------------------------------------------------------------------------------
# EC2 Resources
#------------------------------------------------------------------------------

variable "ec2_resources" {
  description = "List of EC2 resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
      name = string
      overrides = optional(object({
        severity         = optional(string)
        description      = optional(string)
        cpu_threshold    = optional(number)
        memory_threshold = optional(number)
      }), {})
    }))
  }))
  default = []
}

#------------------------------------------------------------------------------
# ASG Resources
#------------------------------------------------------------------------------

variable "asg_resources" {
  description = "List of Auto Scaling Group resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
      name             = string
      desired_capacity = number
      overrides = optional(object({
        severity    = optional(string)
        description = optional(string)
      }), {})
    }))
  }))
  default = []
}

#------------------------------------------------------------------------------
# Lambda Resources
#------------------------------------------------------------------------------

variable "lambda_resources" {
  description = "List of Lambda resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
      name       = string
      timeout_ms = number
      overrides = optional(object({
        severity              = optional(string)
        description           = optional(string)
        duration_threshold_ms = optional(number)
      }), {})
    }))
  }))
  default = []
}

variable "lambda_concurrency_threshold" {
  description = "Threshold for ClaimedAccountConcurrency alarm"
  type        = number
  default     = 900
}

#------------------------------------------------------------------------------
# RDS Resources
#------------------------------------------------------------------------------

variable "rds_resources" {
  description = "List of RDS/Aurora resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
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
  }))
  default = []
}

#------------------------------------------------------------------------------
# S3 Resources
#------------------------------------------------------------------------------

variable "s3_resources" {
  description = "List of S3 bucket resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
      name = string
      overrides = optional(object({
        severity            = optional(string)
        description         = optional(string)
        error_5xx_threshold = optional(number)
        replication_enabled = optional(bool)
      }), {})
    }))
  }))
  default = []
}

#------------------------------------------------------------------------------
# ElastiCache Resources
#------------------------------------------------------------------------------

variable "elasticache_resources" {
  description = "List of ElastiCache resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
      name = string
      overrides = optional(object({
        severity         = optional(string)
        description      = optional(string)
        cpu_threshold    = optional(number)
        memory_threshold = optional(number)
      }), {})
    }))
  }))
  default = []
}

#------------------------------------------------------------------------------
# OpenSearch Resources
#------------------------------------------------------------------------------

variable "opensearch_resources" {
  description = "List of OpenSearch resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
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
  }))
  default = []
}

#------------------------------------------------------------------------------
# SES Resources
#------------------------------------------------------------------------------

variable "ses_resources" {
  description = "List of SES resources to monitor, grouped by project"
  type = list(object({
    project = string
    resources = list(object({
      name = string
      overrides = optional(object({
        severity              = optional(string)
        description           = optional(string)
        bounce_rate_threshold = optional(number)
      }), {})
    }))
  }))
  default = []
}

#------------------------------------------------------------------------------
# CloudFront Resources (Global - us-east-1)
#------------------------------------------------------------------------------

variable "cloudfront_resources" {
  description = "List of CloudFront distributions to monitor, grouped by project. Note: CloudFront metrics are only available in us-east-1."
  type = list(object({
    project = string
    resources = list(object({
      distribution_id = string
      name            = optional(string) # Friendly name for alarm naming
      overrides = optional(object({
        severity                 = optional(string)
        description              = optional(string)
        error_4xx_threshold      = optional(number)
        error_5xx_threshold      = optional(number)
        origin_latency_threshold = optional(number)
        cache_hit_rate_threshold = optional(number)
      }), {})
    }))
  }))
  default = []
}
