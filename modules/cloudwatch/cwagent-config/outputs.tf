output "parameter_names" {
  description = "SSM parameter name per host group — the value to pass to `fetch-config -c ssm:<name>` on the instance."
  value       = { for k, p in aws_ssm_parameter.cwagent_config : k => p.name }
}

output "parameter_arns" {
  description = "SSM parameter ARN per host group (for scoping instance-profile ssm:GetParameter statements)."
  value       = { for k, p in aws_ssm_parameter.cwagent_config : k => p.arn }
}

output "config_json" {
  description = "Rendered agent config per host group, as stored. Diff this against a host's live config to confirm it has re-fetched."
  value       = local.config_json
}

output "dimension_values" {
  description = "cwagent_dimension_value per host group. Cross-check against the asg/jmx entries' values — the match is by hand today."
  value       = { for k, c in local.configs : k => c.cwagent_dimension_value }
}
