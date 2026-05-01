# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-01

### Changed

- **`terraform-apply.yml`** — converted from push-triggered auto-apply to `workflow_dispatch`-only; the apply workflow no longer runs on merge to `main` since there is no live AWS account backing this portfolio repo. A top-of-file comment and ADR-005 document the decision.
- **`tflint-and-checkov.yml`** — repaired the lint/security pipeline so it runs fully credential-less:
  - Replaced `bridgecrewio/checkov-action@v12` (passes deprecated `--skip_check` underscore flag that checkov v3.x rejects) with a direct `pip install checkov` + CLI invocation using `--skip-check`.
  - Worked around a checkov v3.x bug where config-file `skip_check` entries are re-applied using the old `--skip_check` flag that its own parser no longer accepts; moved the skip list to an env var and pass it as `--skip-check` on the CLI.
  - Fixed four TFLint warnings: added `required_version = ">= 1.5"` to all four module `terraform {}` blocks; removed two genuinely unused data sources from the EKS module; wired the `eks_cluster_name` variable into a new CloudWatch log group for EKS control-plane logs.
  - Added push-path triggers for `.checkov.yaml` and the workflow file itself.
  - Guarded the Infracost job behind `secrets.INFRACOST_API_KEY != ''` so it skips silently on repos without the secret.

### Added

- **ADR-005** (`docs/adr/005-reference-architecture-not-deployed.md`) — documents the reference-architecture decision: cost rationale (~$743/month to run as designed), what is and isn't deployed, and step-by-step instructions for deploying to a real AWS account.
- **Reference-architecture callout** in README (below badges) explaining that CI is credential-less and apply is manual-dispatch.
- **VPC module improvements** — `map_public_ip_on_launch = false` on public subnets (ALB uses ENIs, not auto-assigned IPs); `aws_default_security_group` resource to explicitly restrict the VPC default SG; `flow_logs_retention_days` default raised from 30 to 365 days; added `aws_cloudwatch_log_group` for EKS control-plane logs to the monitoring module.

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
