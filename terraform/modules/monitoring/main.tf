terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── SNS Topics ────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "p1_alerts" {
  name              = "${var.name}-p1-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = var.tags
}

resource "aws_sns_topic" "p2_alerts" {
  name              = "${var.name}-p2-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = var.tags
}

resource "aws_sns_topic_subscription" "pagerduty_p1" {
  topic_arn = aws_sns_topic.p1_alerts.arn
  protocol  = "https"
  endpoint  = var.pagerduty_sns_endpoint
}

resource "aws_sns_topic_subscription" "pagerduty_p2" {
  topic_arn = aws_sns_topic.p2_alerts.arn
  protocol  = "https"
  endpoint  = var.pagerduty_sns_endpoint
}

resource "aws_sns_topic_subscription" "slack_p1" {
  topic_arn = aws_sns_topic.p1_alerts.arn
  protocol  = "https"
  endpoint  = var.slack_sns_endpoint
}

resource "aws_sns_topic_subscription" "slack_p2" {
  topic_arn = aws_sns_topic.p2_alerts.arn
  protocol  = "https"
  endpoint  = var.slack_sns_endpoint
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "application" {
  name              = "/production-platform/${var.environment}/application"
  retention_in_days = var.log_retention_days["application"]

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/production-platform/${var.environment}/access"
  retention_in_days = var.log_retention_days["access"]

  tags = var.tags
}

# ── ALB Alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "${var.name}-alb-5xx-errors"
  alarm_description   = "ALB is returning 5xx errors — check pod health and logs"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.p2_alerts.arn]
  ok_actions    = [aws_sns_topic.p2_alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  alarm_name          = "${var.name}-alb-p99-response-time"
  alarm_description   = "ALB p99 response time exceeds 2s — investigate pod resource constraints"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  extended_statistic  = "p99"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  threshold           = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.p2_alerts.arn]
  ok_actions    = [aws_sns_topic.p2_alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.name}-alb-unhealthy-hosts"
  alarm_description   = "ALB target group has unhealthy hosts — pods are failing health checks"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.p2_alerts.arn]
  ok_actions    = [aws_sns_topic.p2_alerts.arn]

  tags = var.tags
}

# ── RDS Alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu-high"
  alarm_description   = "Aurora writer CPU > 80% — investigate slow queries"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.rds_cluster_identifier
    Role                = "WRITER"
  }

  alarm_actions = [aws_sns_topic.p2_alerts.arn]
  ok_actions    = [aws_sns_topic.p2_alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name}-rds-connections-high"
  alarm_description   = "Aurora connection count > 400 — approaching max_connections limit"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 400
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.rds_cluster_identifier
  }

  alarm_actions = [aws_sns_topic.p2_alerts.arn]
  ok_actions    = [aws_sns_topic.p2_alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  alarm_name          = "${var.name}-rds-replica-lag"
  alarm_description   = "Aurora replica lag > 500ms — read queries may return stale data"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 500
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.rds_cluster_identifier
  }

  alarm_actions = [aws_sns_topic.p2_alerts.arn]
  ok_actions    = [aws_sns_topic.p2_alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory" {
  alarm_name          = "${var.name}-rds-low-memory"
  alarm_description   = "Aurora freeable memory < 256MB — consider scaling instance class"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Minimum"
  threshold           = 268435456 # 256 MB in bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.rds_cluster_identifier
    Role                = "WRITER"
  }

  alarm_actions = [aws_sns_topic.p2_alerts.arn]
  ok_actions    = [aws_sns_topic.p2_alerts.arn]

  tags = var.tags
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Request Count & 5xx Rate"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Requests" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "5xx Errors", color = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Response Time (p50 / p99)"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p99", label = "p99", color = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Aurora CPU & Connections"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", var.rds_cluster_identifier, "Role", "WRITER", { stat = "Average", label = "CPU Writer %" }],
            ["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", var.rds_cluster_identifier, { stat = "Maximum", label = "Connections", yAxis = "right" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Aurora Replica Lag & FreeableMemory"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "AuroraReplicaLag", "DBClusterIdentifier", var.rds_cluster_identifier, { stat = "Maximum", label = "Replica Lag (ms)" }],
            ["AWS/RDS", "FreeableMemory", "DBClusterIdentifier", var.rds_cluster_identifier, "Role", "WRITER", { stat = "Minimum", label = "Freeable Memory", yAxis = "right" }]
          ]
        }
      }
    ]
  })
}
