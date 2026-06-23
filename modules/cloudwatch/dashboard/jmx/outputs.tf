output "dashboard_name" {
  description = "Name of the created CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.jmx.dashboard_name
}

output "dashboard_json" {
  description = "Rendered dashboard body (import this JSON into the console to reproduce the dashboard)."
  value       = aws_cloudwatch_dashboard.jmx.dashboard_body
}
