variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "pagerduty_sns_endpoint" {
  type      = string
  sensitive = true
}

variable "slack_sns_endpoint" {
  type      = string
  sensitive = true
}
