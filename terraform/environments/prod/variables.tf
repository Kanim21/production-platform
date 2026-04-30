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

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the EKS public API endpoint (VPN, bastion, CI runner IPs)."
}
