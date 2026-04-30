output "p1_sns_topic_arn" {
  description = "ARN of the P1 (critical) alert SNS topic."
  value       = aws_sns_topic.p1_alerts.arn
}

output "p2_sns_topic_arn" {
  description = "ARN of the P2 (high) alert SNS topic."
  value       = aws_sns_topic.p2_alerts.arn
}

output "application_log_group_name" {
  description = "CloudWatch log group name for application logs."
  value       = aws_cloudwatch_log_group.application.name
}

output "access_log_group_name" {
  description = "CloudWatch log group name for access logs."
  value       = aws_cloudwatch_log_group.access_logs.name
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL (requires AWS console access)."
  value       = "https://console.aws.amazon.com/cloudwatch/home#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
