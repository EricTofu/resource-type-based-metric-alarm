variable "service" {
  description = "Service name (e.g., 'billing')."
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

# Resource lists - no project field; the stack injects project = var.service
variable "alb_resources" {
  description = "List of ALB resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity            = optional(string)
      description         = optional(string)
      http_5xx_threshold  = optional(number)
      unhealthy_threshold = optional(number)
      response_time_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "apigateway_resources" {
  description = "List of API Gateway resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      error_5xx_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "asg_resources" {
  description = "List of ASG resources to monitor."
  type = list(object({
    name            = string
    desired_capacity = number
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      capacity_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "cloudfront_resources" {
  description = "List of CloudFront resources to monitor."
  type = list(object({
    distribution_id = string
    name            = optional(string)
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      error_4xx_threshold = optional(number)
      error_5xx_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "ec2_resources" {
  description = "List of EC2 resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity          = optional(string)
      description       = optional(string)
      cpu_threshold     = optional(number)
      memory_threshold  = optional(number)
    }), {})
  }))
  default = []
}

variable "elasticache_resources" {
  description = "List of ElastiCache resources to monitor."
  type = list(object({
    name     = string
    type     = string  # redis or memcached
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      cpu_threshold   = optional(number)
      memory_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "lambda_resources" {
  description = "List of Lambda resources to monitor."
  type = list(object({
    name       = string
    timeout_ms = number
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      duration_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "opensearch_resources" {
  description = "List of OpenSearch resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      cpu_threshold   = optional(number)
      memory_threshold = optional(number)
      storage_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "rds_resources" {
  description = "List of RDS resources to monitor."
  type = list(object({
    name         = string
    type         = string  # cluster or standalone
    instance_class = optional(string)
    engine       = optional(string)
    serverless   = optional(bool, false)
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      cpu_threshold   = optional(number)
      memory_threshold = optional(number)
      connections_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "s3_resources" {
  description = "List of S3 resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      error_5xx_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "ses_resources" {
  description = "List of SES resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity        = optional(string)
      description     = optional(string)
      bounce_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "lambda_concurrency_threshold" {
  description = "Account-level Lambda concurrency threshold."
  type        = number
  default     = 80
}

variable "common_tags" {
  description = "Tags applied to all resources in this stack."
  type        = map(string)
  default     = {}
}