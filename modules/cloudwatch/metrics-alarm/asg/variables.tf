variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of ASG resources to monitor. Entries with asg_tag_value set use fleet mode (identity-scoped Metrics Insights alarms); entries without it use legacy mode (AutoScalingGroupName dimension alarm only). JVM heap/GC alarms for these instances live in modules/cloudwatch/metrics-alarm/jmx, keyed by the same cwagent_dimension_value."
  type = list(object({
    name             = string
    desired_capacity = number

    # Fleet mode carries the identity twice, once per system, because the two
    # are resolved by different machinery and neither can see the other:
    #   asg_tag_value           value of the <asg_tag_key> tag on the ASG and on
    #                           each instance. Capacity + cpu alarms.
    #   cwagent_dimension_value value of the <cwagent_dimension_key> dimension in
    #                           the agent config. Memory + disk alarms.
    # They are normally the same string. Setting asg_tag_value is what latches
    # fleet mode; cwagent_dimension_value is then required (see validations).
    asg_tag_value           = optional(string)
    cwagent_dimension_value = optional(string)

    enabled = optional(bool, true)
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
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.severity, null) == null
      || try(contains(["WARN", "ERROR", "CRIT"], r.overrides.severity), false)
    ])
    error_message = "overrides.severity must be one of WARN, ERROR, CRIT (case-sensitive) or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.capacity_threshold, null) == null || coalesce(try(r.overrides.capacity_threshold, null), 0) >= 0
    ])
    error_message = "overrides.capacity_threshold must be non-negative or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for t in ["cpu_threshold", "memory_threshold", "disk_threshold"] :
        try(r.overrides[t], null) == null
        || (coalesce(try(r.overrides[t], null), 0) >= 0 && coalesce(try(r.overrides[t], null), 0) <= 100)
      ])
    ])
    error_message = "overrides.cpu_threshold, memory_threshold and disk_threshold must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) :
        contains(
          r.asg_tag_value == null
          ? ["in_service_capacity"]
          : ["in_service_capacity", "cpu", "memory", "disk"],
          m
        )
      ])
    ])
    error_message = "overrides.disabled_alarms must be a subset of [in_service_capacity] for legacy entries (no asg_tag_value) or [in_service_capacity, cpu, memory, disk] for fleet entries."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      r.asg_tag_value != null || (
        try(r.overrides.cpu_threshold, null) == null
        && try(r.overrides.memory_threshold, null) == null
        && try(r.overrides.disk_threshold, null) == null
      )
    ])
    error_message = "the cpu/memory/disk threshold overrides are fleet-mode fields; set asg_tag_value on the entry or remove them."
  }

  # Fleet mode must not be half-configured. asg_tag_value alone leaves the memory
  # and disk queries with no identity to match; because both treat missing data
  # as not breaching, they would sit green forever rather than complain. The
  # reverse (dimension value without a tag value) does not latch fleet mode at
  # all, so the entry would quietly render a legacy alarm instead.
  validation {
    condition = alltrue([
      for r in var.resources :
      (r.asg_tag_value == null) == (r.cwagent_dimension_value == null)
    ])
    error_message = "asg_tag_value and cwagent_dimension_value must be set together (fleet mode) or both omitted (legacy mode). They are normally the same string."
  }

  validation {
    condition     = length([for r in var.resources : r.asg_tag_value if r.asg_tag_value != null]) == length(distinct([for r in var.resources : r.asg_tag_value if r.asg_tag_value != null]))
    error_message = "asg_tag_value must be unique across fleet entries (one identity = one fleet)."
  }

  # An empty value would pass the null latch and render WHERE tag.<key> = '':
  # the capacity alarm (missing data = breaching) would page forever and the
  # per-instance alarms (notBreaching) would sit green forever. Omit the fields
  # entirely for legacy mode instead.
  #
  # try() is the null guard on purpose: Terraform's || does not short-circuit
  # (so `x == null || trimspace(x) != ""` still errors on null), and coalesce()
  # treats "" as absent (so it would let the empty string through).
  validation {
    condition = alltrue([
      for r in var.resources :
      try(trimspace(r.asg_tag_value), "-") != "" && try(trimspace(r.cwagent_dimension_value), "-") != ""
    ])
    error_message = "asg_tag_value and cwagent_dimension_value must be non-empty, non-whitespace strings; omit them entirely for legacy (non-fleet) entries."
  }
}

variable "sns_topic_arns" {
  description = "SNS topic ARNs mapped by severity"
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
  validation {
    condition = alltrue([
      for k in ["WARN", "ERROR", "CRIT"] :
      can(regex("^arn:aws:sns:", var.sns_topic_arns[k]))
    ])
    error_message = "sns_topic_arns values must be SNS ARNs (starting with arn:aws:sns:)."
  }

}

# This module straddles BOTH identity mechanisms — see "Identity carriers" in
# CLAUDE.md. Keep the two keys below distinct in your head: they are set in
# different systems (AWS resource tags vs the CloudWatch Agent config) and
# nothing checks that they agree. They default to the same string only because
# that is the convention, not because they are the same thing.
variable "asg_tag_key" {
  description = "EC2/ASG resource *tag* key carrying the fleet identity. Used only by the capacity alarm (tag on the ASG) and the cpu alarm (tag on each instance). Requires the account+region 'resource tags on telemetry' setting."
  type        = string
  default     = "AppName"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.asg_tag_key))
    error_message = "asg_tag_key must be letters, numbers or underscore only: anything else needs double-quoting inside the Metrics Insights expression, which this module does not do."
  }
}

variable "cwagent_dimension_key" {
  description = "CloudWatch Agent *dimension* name carrying the fleet identity. Used only by the memory and disk alarms. Must equal the append_dimensions key in the agent config (cwagent/ec2-java/) — a mismatch returns zero series and, because both alarms treat missing data as not breaching, they go silently green."
  type        = string
  default     = "AppName"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.cwagent_dimension_key))
    error_message = "cwagent_dimension_key must be letters, numbers or underscore only: anything else needs double-quoting inside the Metrics Insights expression, which this module does not do."
  }
}

#------------------------------------------------------------------------------
# Default Thresholds (fleet mode)
#------------------------------------------------------------------------------

variable "default_cpu_threshold" {
  description = "Default per-instance CPUUtilization threshold (percent) for fleet entries"
  type        = number
  default     = 85
}

variable "default_memory_threshold" {
  description = "Default per-instance mem_used_percent guardrail threshold for fleet entries. Deliberately high: JVM hosts sit at 75-85% by design; this catches native-memory leaks and rogue processes, not JVM memory pressure (the jmx module owns that)."
  type        = number
  default     = 90
}

variable "default_disk_threshold" {
  description = "Default per-instance disk_used_percent threshold for fleet entries (path /)"
  type        = number
  default     = 85
}

variable "common_tags" {
  description = "Tags merged into every alarm this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
