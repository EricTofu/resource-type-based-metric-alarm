variable "project" {
  description = "Project name for dashboard naming"
  type        = string
}

variable "env" {
  description = "Environment name for dashboard naming"
  type        = string
}

variable "region" {
  description = "Region the JVM metrics live in (widget region)"
  type        = string
}

variable "instances" {
  description = "Java hosts to chart: friendly name + resolved EC2 InstanceId"
  type = list(object({
    name        = string
    instance_id = string
  }))
  validation {
    condition     = alltrue([for i in var.instances : can(regex("^i-[0-9a-f]{8,17}$", i.instance_id))])
    error_message = "instances[*].instance_id must be an EC2 instance id (i-xxxxxxxxxxxxxxxxx). Pass resolved IDs — e.g. module.jmx_alarms[0].instance_ids — not Name tags."
  }
}
