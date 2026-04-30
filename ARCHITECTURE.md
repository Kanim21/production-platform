# Architecture

## Overview

production-platform is a three-tier application platform built on AWS. Every architectural decision prioritizes operability: the ability for an on-call engineer to understand what's broken and fix it in the middle of the night without reading source code.

## Network Design

### VPC Layout

```
VPC: 10.0.0.0/16

Public subnets  (10.0.0.0/20,  10.0.16.0/20,  10.0.32.0/20)   — ALB, NAT GWs
Private subnets (10.0.48.0/20, 10.0.64.0/20,  10.0.80.0/20)   — EKS nodes
Database subnets(10.0.96.0/20, 10.0.112.0/20, 10.0.128.0/20)  — Aurora, ElastiCache
```

Three tiers, three AZs each. Database subnets have no route table entry pointing at an internet gateway or NAT gateway — a database-subnet resource cannot initiate outbound internet connections by design, not by policy.

### Traffic Flow

```
Internet → CloudFront → WAF ACL → ALB (public subnet)
                                    ↓
                              Target Groups
                              ↙          ↘
                    EKS: Go API      EKS: React web (nginx)
                         ↓
                    Aurora PostgreSQL (database subnet)
                    ElastiCache Redis  (database subnet)
```

EKS nodes live in private subnets. Outbound traffic (ECR pulls, Secrets Manager API, S3 for state) exits through NAT Gateways. VPC Endpoints for S3, ECR, and Secrets Manager reduce NAT costs and keep that traffic off the internet.

## Compute — EKS

### Cluster Design

EKS 1.30 with managed node groups. Two node groups:

**system node group** (`m6i.large`, on-demand)
- Runs: kube-system pods, cluster-autoscaler, aws-load-balancer-controller, cert-manager
- Taint: `node.kubernetes.io/role=system:NoSchedule`

**api node group** (`m6i.xlarge`, on-demand, min=2 max=20)
- Runs: Go API pods exclusively
- PodDisruptionBudget: minAvailable=2 at all times
- HPA: CPU 70% target, scale-up 30s, scale-down 300s stabilization

**workers node group** (`m6i.large`, Spot, min=1 max=10)
- Runs: monitoring stack, batch jobs, web pods
- Node Termination Handler: drains nodes on Spot interruption notice (2-min warning)

### IRSA (IAM Roles for Service Accounts)

Every pod that touches AWS services has a dedicated IAM role. The OIDC provider is created by the EKS module and trusted by each service account role. No pod runs with ambient EC2 instance role permissions.

Service accounts with dedicated roles:
- `api-sa` → Secrets Manager read for DB credentials
- `cluster-autoscaler-sa` → EC2 Auto Scaling group describe/modify
- `aws-load-balancer-controller-sa` → ELBv2, EC2, ACM, WAF
- `ebs-csi-controller-sa` → EC2 volume create/attach/delete
- `external-secrets-sa` → Secrets Manager read (broad, for external-secrets-operator)

## Data Tier

### Aurora PostgreSQL

Aurora Serverless v2 is explicitly *not* used here. Serverless v2 has cold-start latency spikes that are unacceptable for a checkout flow. We use provisioned Aurora with:

- `db.r7g.large` writer + 1 reader in a separate AZ
- Storage auto-scaling: 20 GB → 128 TB without downtime
- Automated backups: 14-day retention, PITR to 5-minute granularity
- Encryption: AWS-managed KMS key per environment
- Parameter group: `max_connections=500` (RDS Proxy in the roadmap)
- Deletion protection: enabled in staging and prod

Failover: Aurora promotes the reader to writer in ~30s. The cluster endpoint DNS record updates automatically. Application reconnect logic uses exponential backoff with jitter.

### Secrets Management

Database credentials are not in Terraform state. The RDS module generates a random password, stores it in Secrets Manager, and outputs the secret ARN. The application reads credentials at startup via the AWS SDK (not env vars). Secrets Manager rotation is configured with a 30-day rotation period using the provided Lambda rotation function.

## Delivery Pipeline

### Environments

| Environment | Account strategy | Auto-deploy | Approval |
|---|---|---|---|
| dev | Same account, isolated state | Yes, on branch push | None |
| staging | Same account, isolated state | Yes, on main merge | None |
| prod | Separate account (recommended) | No | Manual in GitHub |

For a portfolio project, all environments share one AWS account with isolated S3 state prefixes. A production deployment would use separate AWS accounts per environment via AWS Organizations.

### GitOps Flow

```
Developer PR
    → tflint + Checkov (blocking)
    → terraform plan posted as PR comment
    → Code review + approval
    → Merge to main
        → terraform apply (dev)
        → terraform apply (staging)
        → Docker build + push to ECR
        → Helm upgrade (staging)
        → Manual approval gate
            → terraform apply (prod)
            → Helm upgrade (prod)
```

### OIDC Authentication

GitHub Actions never stores AWS credentials. The workflow assumes an IAM role via OIDC:

```yaml
permissions:
  id-token: write
  contents: read

- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::ACCOUNT:role/github-actions-REPO
    aws-region: us-east-1
```

The IAM role trust policy scopes access to a specific GitHub org/repo/branch, preventing credential abuse from forks or unrelated repos.

## Observability

### Metrics

kube-prometheus-stack deploys:
- Prometheus (30-day retention, 50 GB PVC)
- Alertmanager (routes to PagerDuty + Slack)
- Grafana (dashboards for EKS, Aurora, ALB, application)
- node-exporter (DaemonSet on all nodes)
- kube-state-metrics

Key SLO alerts:
- `APIErrorRate` > 1% over 5m → P2
- `APILatencyP99` > 200ms over 5m → P2
- `APILatencyP99` > 500ms over 2m → P1
- `DBConnectionsNearMax` > 80% → P2
- `NodeMemoryPressure` → P2

### Logs

All container logs ship to CloudWatch Logs via Fluent Bit DaemonSet. Log groups are organized as `/production-platform/{environment}/{service}`. Retention: 30 days dev, 90 days staging, 365 days prod.

Fluent Bit is chosen over Fluentd for lower memory footprint (~50 MB vs ~200 MB per node).

### Traces

OpenTelemetry SDK in the Go API, exporting to AWS X-Ray. Trace sampling at 5% in prod (cost-controlled), 100% in dev/staging.

## State Management

Remote state in S3 with DynamoDB locking. One state file per environment, no sharing.

```
s3://production-platform-tfstate-{account_id}/
  dev/terraform.tfstate
  staging/terraform.tfstate
  prod/terraform.tfstate

DynamoDB: production-platform-tfstate-lock
  PK: LockID (string)
```

State bucket: versioning enabled, server-side encryption (SSE-S3), public access blocked, access logging enabled. The bucket itself is provisioned by the `make bootstrap-state` target before Terraform runs.

## Cost Model (estimated, us-east-1)

| Component | Dev | Prod |
|---|---|---|
| EKS cluster | $72/mo | $72/mo |
| EC2 nodes (2× m6i.large) | $140/mo | $560/mo (4× m6i.xlarge) |
| Aurora (r7g.large) | $250/mo | $500/mo (writer + reader) |
| NAT Gateways | $32/mo (1×) | $96/mo (3×) |
| ALB | $22/mo | $22/mo |
| CloudFront | ~$5/mo | ~$50/mo |
| Misc (ECR, S3, SM) | ~$20/mo | ~$40/mo |
| **Total** | **~$540/mo** | **~$1,340/mo** |

Prod cost comes down significantly with Savings Plans on the EC2 nodes (~30%) and Spot for the workers node group (~70% for those nodes).
