terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ── KMS Key ───────────────────────────────────────────────────────────────────

resource "aws_kms_key" "rds" {
  description             = "${var.name} Aurora encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = var.tags
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name}-aurora"
  target_key_id = aws_kms_key.rds.key_id
}

# ── Master Password — stored in Secrets Manager, not in state ─────────────────

resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.name}/db-credentials"
  description             = "Aurora master credentials for ${var.name}"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
  kms_key_id              = aws_kms_key.rds.arn

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_rds_cluster.this.endpoint
    port     = 5432
    dbname   = var.database_name
    engine   = "postgres"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "aurora" {
  name        = "${var.name}-aurora-sg"
  description = "Allow PostgreSQL from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  tags = merge(var.tags, { Name = "${var.name}-aurora-sg" })
}

# ── Parameter Group ───────────────────────────────────────────────────────────

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.name}-aurora-pg15"
  family      = "aurora-postgresql15"
  description = "Custom parameter group for ${var.name}"

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  tags = var.tags
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-aurora-pg15-instance"
  family      = "aurora-postgresql15"
  description = "Instance parameter group for ${var.name}"

  tags = var.tags
}

# ── Aurora Cluster ────────────────────────────────────────────────────────────

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name

  engine         = "aurora-postgresql"
  engine_version = var.engine_version
  engine_mode    = "provisioned"

  database_name   = var.database_name
  master_username = var.master_username
  master_password = random_password.master.result

  db_subnet_group_name            = var.db_subnet_group_name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window

  enabled_cloudwatch_logs_exports = ["postgresql"]

  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final-snapshot"

  apply_immediately = var.environment != "prod"

  tags = var.tags
}

# ── Aurora Instances ──────────────────────────────────────────────────────────

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name}-writer"
  cluster_identifier = aws_rds_cluster.this.id

  engine         = aws_rds_cluster.this.engine
  engine_version = aws_rds_cluster.this.engine_version
  instance_class = var.instance_class

  db_parameter_group_name = aws_db_parameter_group.this.name

  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds.arn
  performance_insights_retention_period = var.environment == "prod" ? 731 : 7

  auto_minor_version_upgrade = true
  apply_immediately          = var.environment != "prod"

  tags = merge(var.tags, { Name = "${var.name}-writer" })
}

resource "aws_rds_cluster_instance" "readers" {
  count = var.reader_count

  identifier         = "${var.name}-reader-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this.id

  engine         = aws_rds_cluster.this.engine
  engine_version = aws_rds_cluster.this.engine_version
  instance_class = var.instance_class

  db_parameter_group_name = aws_db_parameter_group.this.name

  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds.arn
  performance_insights_retention_period = var.environment == "prod" ? 731 : 7

  auto_minor_version_upgrade = true
  apply_immediately          = var.environment != "prod"

  tags = merge(var.tags, { Name = "${var.name}-reader-${count.index + 1}" })
}

# ── Enhanced Monitoring IAM Role ──────────────────────────────────────────────

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── Secrets Manager Rotation ──────────────────────────────────────────────────

resource "aws_secretsmanager_secret_rotation" "db_credentials" {
  secret_id           = aws_secretsmanager_secret.db_credentials.id
  rotation_lambda_arn = aws_lambda_function.secret_rotation.arn

  rotation_rules {
    automatically_after_days = 30
  }
}

# Placeholder Lambda for secret rotation — in practice use the AWS-managed
# Serverless Application Repository rotation function for Aurora PostgreSQL.
resource "aws_lambda_function" "secret_rotation" {
  function_name = "${var.name}-secret-rotation"
  role          = aws_iam_role.secret_rotation_lambda.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"
  timeout       = 30

  filename         = "${path.module}/rotation_placeholder.zip"
  source_code_hash = filebase64sha256("${path.module}/rotation_placeholder.zip")

  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${data.aws_region.current.name}.amazonaws.com"
    }
  }

  vpc_config {
    subnet_ids         = []
    security_group_ids = []
  }

  tags = var.tags
}

data "aws_region" "current" {}

resource "aws_iam_role" "secret_rotation_lambda" {
  name = "${var.name}-secret-rotation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "secret_rotation_lambda_basic" {
  role       = aws_iam_role.secret_rotation_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "secret_rotation_lambda" {
  name = "${var.name}-secret-rotation-policy"
  role = aws_iam_role.secret_rotation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage"]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetRandomPassword"]
        Resource = "*"
      }
    ]
  })
}
