output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "rds_cluster_endpoint" {
  value     = module.rds.cluster_endpoint
  sensitive = true
}

output "db_credentials_secret_arn" {
  value = module.rds.credentials_secret_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway IPs to whitelist in external systems."
  value       = module.vpc.nat_gateway_public_ips
}
