terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  environment = "prod"
  name        = "production-platform-prod"

  common_tags = {
    Project     = "production-platform"
    Environment = local.environment
    ManagedBy   = "terraform"
    Repository  = "github.com/your-org/production-platform"
  }

  azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  name = local.name
  cidr = "10.2.0.0/16"
  azs  = local.azs

  public_subnet_cidrs   = ["10.2.0.0/20", "10.2.16.0/20", "10.2.32.0/20"]
  private_subnet_cidrs  = ["10.2.48.0/20", "10.2.64.0/20", "10.2.80.0/20"]
  database_subnet_cidrs = ["10.2.96.0/20", "10.2.112.0/20", "10.2.128.0/20"]

  # NAT per AZ in prod — cross-AZ NAT traffic during AZ failure is unacceptable
  single_nat_gateway = false

  enable_vpc_flow_logs     = true
  flow_logs_retention_days = 90

  tags = local.common_tags
}

# ── EKS ───────────────────────────────────────────────────────────────────────

module "eks" {
  source = "../../modules/eks"

  name               = local.name
  kubernetes_version = "1.30"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # Restrict API access to known CIDRs in prod (VPN + CI runner IPs)
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.allowed_cidr_blocks

  system_node_group = {
    instance_types = ["m6i.large"]
    min_size       = 2
    max_size       = 4
    desired_size   = 2
    disk_size_gb   = 50
  }

  api_node_group = {
    instance_types = ["m6i.xlarge"]
    min_size       = 2
    max_size       = 20
    desired_size   = 4
    disk_size_gb   = 50
  }

  worker_node_group = {
    instance_types = ["m6i.large", "m5.large", "m5a.large", "m5n.large"]
    min_size       = 2
    max_size       = 10
    desired_size   = 2
    disk_size_gb   = 50
  }

  cluster_log_types          = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cluster_log_retention_days = 365

  tags = local.common_tags
}

# ── RDS ───────────────────────────────────────────────────────────────────────

module "rds" {
  source = "../../modules/rds"

  name        = local.name
  environment = local.environment

  vpc_id               = module.vpc.vpc_id
  db_subnet_group_name = module.vpc.db_subnet_group_name

  allowed_security_group_ids = [module.eks.node_security_group_id]

  instance_class = "db.r7g.large"
  reader_count   = 1

  backup_retention_period      = 14
  preferred_backup_window      = "02:00-03:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  deletion_protection = true
  skip_final_snapshot = false

  tags = local.common_tags
}

# ── Monitoring ────────────────────────────────────────────────────────────────

module "monitoring" {
  source = "../../modules/monitoring"

  name        = local.name
  environment = local.environment

  eks_cluster_name       = module.eks.cluster_name
  rds_cluster_identifier = module.rds.cluster_identifier
  alb_arn_suffix         = ""

  pagerduty_sns_endpoint = var.pagerduty_sns_endpoint
  slack_sns_endpoint     = var.slack_sns_endpoint

  log_retention_days = {
    application = 90
    access      = 365
    audit       = 365
  }

  tags = local.common_tags
}
