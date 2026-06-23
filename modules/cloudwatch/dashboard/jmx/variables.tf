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
}
