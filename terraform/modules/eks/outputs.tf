output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_security_group_id" {
  description = "Security group ID for worker nodes."
  value       = aws_security_group.nodes.id
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler (IRSA)."
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (IRSA)."
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "ebs_csi_driver_role_arn" {
  description = "IAM role ARN for EBS CSI driver (IRSA)."
  value       = aws_iam_role.ebs_csi.arn
}
