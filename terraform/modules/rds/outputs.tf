output "cluster_endpoint" {
  description = "Writer endpoint for the Aurora cluster."
  value       = aws_rds_cluster.this.endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint for the Aurora cluster."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "cluster_identifier" {
  description = "Aurora cluster identifier."
  value       = aws_rds_cluster.this.cluster_identifier
}

output "cluster_port" {
  description = "Database port."
  value       = aws_rds_cluster.this.port
}

output "database_name" {
  description = "Name of the default database."
  value       = aws_rds_cluster.this.database_name
}

output "credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials."
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "security_group_id" {
  description = "Security group ID for the Aurora cluster."
  value       = aws_security_group.aurora.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for Aurora encryption."
  value       = aws_kms_key.rds.arn
}
