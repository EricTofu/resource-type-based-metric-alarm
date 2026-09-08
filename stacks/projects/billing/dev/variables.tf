variable "project" {
  description = "Project name (e.g., 'billing'). Used as the Project tag value and the alarm-name prefix."
  type        = string
}

variable "env" {
  description = "Environment / account tier (e.g., 'dev', 'stg', 'prod')."
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

variable "lambda_concurrency_alarm_enabled" {
  description = "Whether to create the account-level Lambda concurrency alarm."
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# Resource lists — no project field; the stack injects project = var.project.
# Override field names must exactly match the library module's resources type.
#------------------------------------------------------------------------------

variable "alb_resources" {
  description = "ALB resources to monitor."
  type = list(object({
    name          = string
    target_groups = optional(list(string), [])
    overrides = optional(object({
      severity                       = optional(string)
      description                    = optional(string)
      elb_5xx_threshold              = optional(number)
      target_5xx_threshold           = optional(number)
      unhealthy_host_threshold       = optional(number)
      target_response_time_threshold = optional(number)
      disabled_alarms                = optional(set(string), [])
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
      disabled_alarms     = optional(set(string), [])
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
      disk_threshold   = optional(number)
      disabled_alarms  = optional(set(string), [])
    }), {})
  }))
  default = []
}

variable "asg_resources" {
  description = "ASG resources to monitor. Set asg_tag_value + cwagent_dimension_value for fleet mode (identity-scoped Metrics Insights alarms); omit both for legacy mode. See docs/superpowers/specs/2026-07-24-asg-fleet-alarms-design.md."
  type = list(object({
    name             = string
    desired_capacity = number
    # Fleet mode: both or neither (the module validates the pairing). Normally
    # the same string — they are separate because they are set in separate
    # systems, the resource tag and the agent config.
    asg_tag_value           = optional(string)
    cwagent_dimension_value = optional(string)
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
      cpu_threshold      = optional(number)
      memory_threshold   = optional(number)
      disk_threshold     = optional(number)
      disabled_alarms    = optional(set(string), [])
    }), {})
  }))
  default = []
}

# ─── Fleet identity: two mechanisms, one value ────────────────────────────────
#
# Both name WHERE-clause keys, both default to "AppName", and they are NOT the
# same thing. The VALUES are per-entry (asg_tag_value / cwagent_dimension_value
# on each resource); only the keys live here. See "Identity carriers" in
# CLAUDE.md.
#
#   asg_tag_key            AWS resource tag on the ASG and on each instance.
#                          Only the asg module, only capacity + cpu. Needs the
#                          "resource tags on telemetry" setting, per account AND
#                          per region.
#
#   cwagent_dimension_key  A dimension the CloudWatch Agent stamps on what it
#                          publishes. asg memory/disk, all jmx alarms, and every
#                          JVM dashboard widget. Also read by cwagent_configs
#                          below, which writes the agent config that emits it —
#                          so one apply moves both sides, but only Parameter
#                          Store: hosts emit the old dimension until they
#                          re-fetch.
#
# Changing either one is a multi-system edit, and the two fail differently:
#
#   asg_tag_key            also retag the ASG *and* its instances
#                          (propagate_at_launch), and update ASG_TAG_KEY in
#                          .github/workflows/preflight.yml. Half-done, capacity
#                          (breaching) pages forever while cpu (notBreaching)
#                          sits green.
#   cwagent_dimension_key  also re-fetch the config on every host (the apply
#                          rewrites the parameter, not the running agent), and
#                          update CWAGENT_DIMENSION_KEY in the same workflow.
#                          Half-done, ALL four alarms are notBreaching — nothing
#                          pages, nothing turns red, and only preflight notices.
variable "asg_tag_key" {
  description = "EC2/ASG resource tag key carrying the fleet identity. Used only by the asg module's capacity and cpu alarms."
  type        = string
  default     = "AppName"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.asg_tag_key))
    error_message = "asg_tag_key must be letters, numbers or underscore only: anything else needs double-quoting inside the Metrics Insights expression, which the modules do not do."
  }
}

variable "cwagent_dimension_key" {
  description = "CloudWatch Agent dimension name carrying the fleet identity. Feeds the asg memory/disk alarms, the jmx alarms and the JVM dashboard from one place, because all three read the same agent config."
  type        = string
  default     = "AppName"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.cwagent_dimension_key))
    error_message = "cwagent_dimension_key must be letters, numbers or underscore only: anything else needs double-quoting inside the Metrics Insights expression, which the modules do not do."
  }
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
      errors_threshold      = optional(number)
      throttles_threshold   = optional(number)
      disabled_alarms       = optional(set(string), [])
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
      disabled_alarms                        = optional(set(string), [])
    }), {})
  }))
  default = []
}

variable "s3_resources" {
  description = "S3 resources to monitor."
  type = list(object({
    name = string
    overrides = optional(object({
      severity                       = optional(string)
      description                    = optional(string)
      error_5xx_threshold            = optional(number)
      replication_enabled            = optional(bool)
      replication_destination_bucket = optional(string)
      replication_rule_id            = optional(string)
      disabled_alarms                = optional(set(string), [])
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
      disabled_alarms  = optional(set(string), [])
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
      disabled_alarms              = optional(set(string), [])
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
      disabled_alarms       = optional(set(string), [])
    }), {})
  }))
  default = []
}

variable "cloudfront_resources" {
  description = "CloudFront distributions to monitor."
  type = list(object({
    distribution_id = string
    name            = optional(string) # Friendly name for alarm naming
    overrides = optional(object({
      severity                 = optional(string)
      description              = optional(string)
      error_4xx_threshold      = optional(number)
      error_5xx_threshold      = optional(number)
      origin_latency_threshold = optional(number)
      cache_hit_rate_threshold = optional(number)
      disabled_alarms          = optional(set(string), [])
    }), {})
  }))
  default = []
}

variable "efs_resources" {
  description = "EFS file systems to monitor."
  type = list(object({
    file_system_id = string
    name           = optional(string)
    enabled        = optional(bool, true)
    overrides = optional(object({
      severity                  = optional(string)
      description               = optional(string)
      throughput_util_threshold = optional(number)
      period                    = optional(number)
      evaluation_periods        = optional(number)
      disabled_alarms           = optional(set(string), [])
    }), {})
  }))
  default = []
}

variable "jmx_resources" {
  description = "Java host groups to monitor, identified by the CWAgent AppName dimension (see cwagent/ec2-java/). One entry covers every instance sharing that AppName — an ASG fleet or interchangeable standalone hosts. `name` is a label only, NOT a Name-tag lookup."
  type = list(object({
    name                    = string
    cwagent_dimension_value = string
    heap_max_bytes          = optional(number)
    process_group           = optional(string)
    enabled                 = optional(bool, true)
    overrides = optional(object({
      severity                = optional(string)
      description             = optional(string)
      heap_threshold          = optional(number)
      heap_evaluation_periods = optional(number)
      gc_time_threshold_ms    = optional(number)
      disabled_alarms         = optional(set(string), [])
    }), {})
  }))
  default = []
}

variable "jmx_dashboard_enabled" {
  description = "Create the per-instance JVM dashboard for the hosts in jmx_resources (requires jmx_resources to be non-empty)."
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# CloudWatch Agent configs (SSM Parameter Store).
#
# The emitting side of the identity contract: cwagent_dimension_key above says
# what the alarm queries ASK FOR, these entries say what the agent PUBLISHES.
# Both move in one apply — but the parameter only changes what a host fetches
# NEXT, so the agents must be restarted before the queries match again.
#------------------------------------------------------------------------------
variable "cwagent_configs" {
  description = "CloudWatch Agent configs to publish, one SSM parameter per host group. `cwagent_dimension_value` must match the asg/jmx entry watching the same fleet. `template` is a file under cwagent/ in this directory carrying this app's `logs` and `jmx` blocks (the module's base has neither) plus any host-metric departure from it; omit it for host metrics only. Dimensions other than the fleet one — `ProcessGroupName` in particular — are written in the overlay, not here."
  type = list(object({
    name                    = string
    cwagent_dimension_value = string
    template                = optional(string)
  }))
  default = []
}

variable "cwagent_parameter_tier" {
  description = "SSM tier for the agent-config parameters. Standard caps the value at 4096 bytes; the rendered config sits close to it."
  type        = string
  default     = "Standard"
}
