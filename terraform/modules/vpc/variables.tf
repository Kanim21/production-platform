variable "name" {
  type        = string
  description = "Name prefix applied to all resources."
}

variable "cidr" {
  type        = string
  description = "VPC CIDR block."
  default     = "10.0.0.0/16"
}

variable "azs" {
  type        = list(string)
  description = "List of Availability Zones (must have exactly 3 for this module)."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for public subnets (one per AZ)."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for private subnets used by EKS nodes (one per AZ)."
}

variable "database_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for database subnets — these subnets have no internet route (one per AZ)."
}

variable "single_nat_gateway" {
  type        = bool
  description = "Use a single shared NAT Gateway instead of one per AZ. Cost-saving for dev; reduces HA for prod."
  default     = false
}

variable "enable_vpc_flow_logs" {
  type        = bool
  description = "Enable VPC Flow Logs to CloudWatch."
  default     = true
}

variable "flow_logs_retention_days" {
  type        = number
  description = "CloudWatch log retention in days for VPC flow logs."
  default     = 365
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
