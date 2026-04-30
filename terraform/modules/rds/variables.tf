variable "name" {
  type        = string
  description = "Name prefix for all RDS resources."
}

variable "environment" {
  type        = string
  description = "Environment name (dev, staging, prod)."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID."
}

variable "db_subnet_group_name" {
  type        = string
  description = "Name of the DB subnet group (output from vpc module)."
}

variable "allowed_security_group_ids" {
  type        = list(string)
  description = "Security group IDs allowed to connect to the database (EKS nodes)."
}

variable "engine_version" {
  type        = string
  description = "Aurora PostgreSQL engine version."
  default     = "15.4"
}

variable "instance_class" {
  type        = string
  description = "Aurora DB instance class."
  default     = "db.r7g.large"
}

variable "database_name" {
  type        = string
  description = "Name of the initial database."
  default     = "platform"
}

variable "master_username" {
  type        = string
  description = "Master DB username."
  default     = "platform_admin"
}

variable "backup_retention_period" {
  type        = number
  description = "Number of days to retain automated backups."
  default     = 14
}

variable "preferred_backup_window" {
  type        = string
  description = "Daily time range for automated backups (UTC)."
  default     = "02:00-03:00"
}

variable "preferred_maintenance_window" {
  type        = string
  description = "Weekly time range for maintenance (UTC)."
  default     = "sun:04:00-sun:05:00"
}

variable "deletion_protection" {
  type        = bool
  description = "Prevent the cluster from being deleted."
  default     = true
}

variable "skip_final_snapshot" {
  type        = bool
  description = "Skip final snapshot on cluster deletion. Set true only for dev."
  default     = false
}

variable "reader_count" {
  type        = number
  description = "Number of reader instances in the Aurora cluster."
  default     = 1
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
