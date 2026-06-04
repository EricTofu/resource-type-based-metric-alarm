variable "common_tags" {
  description = "Tags merged into every alarm resource this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}