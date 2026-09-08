variable "project" {
  description = "Project name (e.g., 'billing'). Used in the parameter name and the Project tag."
  type        = string
}

variable "env" {
  description = "Environment / account tier (e.g., 'dev', 'stg', 'prod'). Used in the parameter name."
  type        = string
}

variable "configs" {
  description = <<-EOT
    Agent configs to publish, one SSM parameter per entry. Each entry is one
    *host group* — every host fetching that parameter reports under the same
    identity, which is exactly the granularity the fleet alarms watch.

    `cwagent_dimension_value` is the string the alarms match on; it must equal
    the `cwagent_dimension_value` on the matching `asg_resources` / `jmx_resources`
    entry, and (normally) the ASG's `asg_tag_value`. `name` is a label: it names
    the parameter, nothing queries it.

    `template` is the project's overlay, a file name under `template_dir`, and it
    is where this app's `logs` and `jmx` blocks live — the module's base template
    carries neither. It may also depart from the base's host metrics: plugins are
    merged one level deep, so a plugin it names is replaced whole and
    `"<plugin>": null` drops one. Omit `template` entirely for a host group that
    wants host metrics only — no JVM, no log shipping.

    Never write the fleet dimension into an overlay: the module stamps
    `<cwagent_dimension_key>` on every plugin after the merge, so it cannot be
    forgotten on one. Any OTHER dimension an app wants — `ProcessGroupName` on a
    jmx block, say — belongs in the overlay's own `append_dimensions`, next to
    the plugin it describes. The module neither writes nor checks those.
  EOT
  type = list(object({
    name                    = string
    cwagent_dimension_value = string
    template                = optional(string)
  }))

  validation {
    condition     = length(distinct([for c in var.configs : c.name])) == length(var.configs)
    error_message = "configs[*].name must be unique: name is the parameter's identity, so a duplicate would silently overwrite another entry's config."
  }

  validation {
    condition     = alltrue([for c in var.configs : can(regex("^[A-Za-z0-9_.-]+$", c.name))])
    error_message = "configs[*].name must be letters, numbers, dot, dash or underscore (it becomes part of the SSM parameter name)."
  }

  validation {
    condition     = alltrue([for c in var.configs : trimspace(c.cwagent_dimension_value) != ""])
    error_message = "configs[*].cwagent_dimension_value must be non-empty: an empty dimension value publishes series no alarm query can match, and every CWAgent-sourced alarm treats missing data as not breaching — permanently green."
  }
}

variable "template_dir" {
  description = "Directory holding the project's overlay templates; each entry's `template` is resolved against it. Pass \"$${path.root}/cwagent\" from the stack — a *.tfvars file cannot reference path.root, so the entries carry a bare file name."
  type        = string
  default     = null

  validation {
    condition     = var.template_dir != null || alltrue([for c in var.configs : c.template == null])
    error_message = "template_dir must be set when any entry declares a template; without it the overlay path resolves against Terraform's working directory, which is not the stack directory."
  }
}

variable "cwagent_dimension_key" {
  description = <<-EOT
    Name of the CWAgent *dimension* carrying the fleet identity, written into
    `append_dimensions` on every metrics plugin. This is the emitting half of the
    contract whose querying half is the identically named variable on the `asg`,
    `jmx` and `dashboard/jmx` modules: Terraform changes what the queries ask for,
    this module changes what the agent emits. They must be the same string, and
    nothing checks that they are — see "Identity carriers" in CLAUDE.md.

    NOT an AWS resource tag; `asg_tag_key` is the separate tag-side mechanism.
  EOT
  type        = string
  default     = "AppName"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.cwagent_dimension_key))
    error_message = "cwagent_dimension_key must be letters, numbers or underscore only, to match the consuming modules' Metrics Insights restriction."
  }
}

variable "required_jvm_metrics" {
  description = "Renamed JVM metric names a jmx overlay must publish, checked by the `jvm_metrics_the_alarms_query` check block. Defaults to what modules/cloudwatch/metrics-alarm/jmx alarms on plus the heap ceiling the JVM dashboard draws. A hand-synced mirror: Terraform cannot read another module's query text."
  type        = list(string)
  default     = ["jvm_memory_heap_used", "jvm_memory_heap_max", "jvm_gc_collections_elapsed"]
}

variable "metrics_collection_interval" {
  description = <<-EOT
    Agent collection interval, seconds. LOAD-BEARING, not a preference: the `jmx`
    pipeline's cumulativetodelta processor publishes `jvm_gc_collections_elapsed`
    as a delta *per interval*, so the JMX module's `gc_time` threshold is read as
    "ms of GC per interval". Halving this silently halves every GC threshold's
    meaning, with no error anywhere. Change it only together with
    `default_gc_time_threshold_ms`; see cwagent/ec2-java/README.md.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.metrics_collection_interval > 0
    error_message = "metrics_collection_interval must be positive."
  }
}

variable "parameter_name_prefix" {
  description = <<-EOT
    Prefix for each parameter name; the entry's `name` is appended.

    The default is deliberately `AmazonCloudWatch-` prefixed: the AWS managed
    policy `CloudWatchAgentServerPolicy` grants `ssm:GetParameter` only on
    `arn:aws:ssm:*:*:parameter/AmazonCloudWatch-*`. A parameter outside that
    prefix needs an extra IAM statement on the instance profile, and without it
    `fetch-config` fails on the host — where Terraform cannot see it.
  EOT
  type        = string
  default     = null
}

variable "tier" {
  description = "SSM parameter tier. Standard caps a value at 4096 bytes; a rendered agent config sits close to that, so Advanced (billed per parameter) is the escape hatch. A precondition checks the size before the API does."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Advanced", "Intelligent-Tiering"], var.tier)
    error_message = "tier must be one of Standard, Advanced, Intelligent-Tiering."
  }
}

variable "common_tags" {
  description = "Tags applied to every parameter created by this module."
  type        = map(string)
  default     = {}
}
