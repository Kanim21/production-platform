# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-30

### Added

- **VPC module** — 3-tier subnet design (public / private / database), 3 AZs, per-AZ NAT Gateways, flow logs
- **EKS module** — managed node groups (system / api / worker), IRSA, OIDC provider, ALB Controller IAM policy, IMDSv2 enforcement
- **RDS module** — Aurora PostgreSQL 15, KMS encryption at rest, Enhanced Monitoring, Performance Insights, Secrets Manager credential storage
- **Monitoring module** — kube-prometheus-stack Helm release, Grafana, Alertmanager, Loki, Fluent Bit
- **Three environments** — `dev`, `staging`, `prod` each with S3/DynamoDB remote Terraform backend
- **GitHub Actions CI/CD** — terraform-plan (PR comments), terraform-apply (merge), app-build (Docker + ECR push), tflint-and-checkov (security gate)
- **OIDC-based AWS authentication** for GitHub Actions — no static keys anywhere
- **Go API scaffold** — health endpoint, structured logging, Dockerfile
- **React web frontend scaffold** — nginx-served static build, Dockerfile
- **PostgreSQL migration** — `001_init.sql` (users, products, orders, order_items schema)
- **Architecture Decision Records** — ADR-001 (EKS over ECS), ADR-002 (Terraform over CDK), ADR-003 (Prometheus over CloudWatch), ADR-004 (RDS secret rotation trade-off)
- **Runbooks** — node-failure, rds-failover, ingress-degraded, rds-secret-rotation (manual stopgap)
- **Mermaid architecture diagram** with rendered PNG
- **Makefile** — `dev-up`, `dev-down`, `plan`, `apply`, `lint`, `checkov` targets
- **tflint** and **Checkov** configuration files
- **CODEOWNERS**, **CONTRIBUTING.md**, **SECURITY.md**, **CHANGELOG.md**
