variable "project" {
  description = "Project name for alarm naming"
  type        = string
}

variable "env" {
  description = "Environment name (dev/stg/prod) for alarm naming"
  type        = string
}

variable "resources" {
  description = "List of ASG resources to monitor. Entries with app_name set use fleet mode (AppName-scoped Metrics Insights alarms); entries without it use legacy mode (AutoScalingGroupName dimension alarm only)."
  type = list(object({
    name             = string
    desired_capacity = number
    app_name         = optional(string)
    heap_max_bytes   = optional(number)
    process_group    = optional(string)
    enabled          = optional(bool, true)
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
      cpu_threshold      = optional(number)
      memory_threshold   = optional(number)
      heap_threshold_pct = optional(number)
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
        for t in ["cpu_threshold", "memory_threshold", "heap_threshold_pct", "disk_threshold"] :
        try(r.overrides[t], null) == null
        || (coalesce(try(r.overrides[t], null), 0) >= 0 && coalesce(try(r.overrides[t], null), 0) <= 100)
      ])
    ])
    error_message = "overrides.cpu_threshold, memory_threshold, heap_threshold_pct and disk_threshold must be between 0 and 100 inclusive, or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) :
        contains(
          r.app_name == null
          ? ["in_service_capacity"]
          : ["in_service_capacity", "cpu", "heap_used", "memory", "disk"],
          m
        )
      ])
    ])
    error_message = "overrides.disabled_alarms must be a subset of [in_service_capacity] for legacy entries (no app_name) or [in_service_capacity, cpu, heap_used, memory, disk] for fleet entries."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      r.app_name != null || (
        r.heap_max_bytes == null
        && r.process_group == null
        && try(r.overrides.cpu_threshold, null) == null
        && try(r.overrides.memory_threshold, null) == null
        && try(r.overrides.heap_threshold_pct, null) == null
        && try(r.overrides.disk_threshold, null) == null
      )
    ])
    error_message = "heap_max_bytes, process_group and the cpu/memory/heap/disk threshold overrides are fleet-mode fields; set app_name on the entry or remove them."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      r.app_name == null
      || contains(try(r.overrides.disabled_alarms, []), "heap_used")
      || (r.heap_max_bytes != null && coalesce(r.heap_max_bytes, 0) > 0)
    ])
    error_message = "Fleet entries must set heap_max_bytes (> 0, the JVM -Xmx in bytes) unless heap_used is in disabled_alarms."
  }
  validation {
    condition     = length([for r in var.resources : r.app_name if r.app_name != null]) == length(distinct([for r in var.resources : r.app_name if r.app_name != null]))
    error_message = "app_name values must be unique across fleet entries (one AppName = one fleet)."
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

variable "app_tag_key" {
  description = "EC2/ASG resource tag key that carries the fleet identity for tag-scoped Metrics Insights queries. The CWAgent dimension name is always AppName regardless of this value."
  type        = string
  default     = "AppName"
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
  description = "Default per-instance mem_used_percent guardrail threshold for fleet entries. Deliberately high: JVM hosts sit at 75-85% by design; this catches off-heap/native leaks and rogue processes, not heap pressure (heap_used does that)."
  type        = number
  default     = 90
}

variable "default_heap_threshold_pct" {
  description = "Default heap_used threshold as a percent of heap_max_bytes for fleet entries"
  type        = number
  default     = 85
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
