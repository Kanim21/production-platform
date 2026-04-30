variable "name" {
  type        = string
  description = "Name prefix for all EKS resources."
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version."
  default     = "1.30"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the cluster is deployed."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EKS node groups."
}

variable "cluster_endpoint_public_access" {
  type        = bool
  description = "Allow public access to the EKS cluster API endpoint."
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the public API endpoint."
  default     = ["0.0.0.0/0"]
}

variable "system_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gb   = number
  })
  description = "Configuration for the system node group (cluster-critical workloads)."
  default = {
    instance_types = ["m6i.large"]
    min_size       = 2
    max_size       = 4
    desired_size   = 2
    disk_size_gb   = 50
  }
}

variable "api_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gb   = number
  })
  description = "Configuration for the API node group (application workloads, on-demand)."
  default = {
    instance_types = ["m6i.xlarge"]
    min_size       = 2
    max_size       = 20
    desired_size   = 2
    disk_size_gb   = 50
  }
}

variable "worker_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gb   = number
  })
  description = "Configuration for the worker node group (Spot, non-critical workloads)."
  default = {
    instance_types = ["m6i.large", "m5.large", "m5a.large"]
    min_size       = 1
    max_size       = 10
    desired_size   = 2
    disk_size_gb   = 50
  }
}

variable "cluster_log_types" {
  type        = list(string)
  description = "EKS control plane log types to enable."
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  type        = number
  description = "CloudWatch log retention for EKS control plane logs."
  default     = 90
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
