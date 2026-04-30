variable "name" {
  type        = string
  description = "Name prefix for monitoring resources."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "eks_cluster_name" {
  type        = string
  description = "EKS cluster name, used for CloudWatch log group naming."
}

variable "rds_cluster_identifier" {
  type        = string
  description = "Aurora cluster identifier for CloudWatch alarm dimensions."
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB ARN suffix for CloudWatch alarm dimensions."
}

variable "pagerduty_sns_endpoint" {
  type        = string
  description = "HTTPS endpoint for PagerDuty SNS subscription (P1/P2 alerts)."
  sensitive   = true
}

variable "slack_sns_endpoint" {
  type        = string
  description = "HTTPS endpoint for Slack SNS subscription (all alerts)."
  sensitive   = true
}

variable "alarm_evaluation_periods" {
  type        = number
  description = "Number of periods over which data is compared to the specified threshold."
  default     = 3
}

variable "log_retention_days" {
  type        = map(number)
  description = "CloudWatch log retention per log group type."
  default = {
    application = 90
    access      = 365
    audit       = 365
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
