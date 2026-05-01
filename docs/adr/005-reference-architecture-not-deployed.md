# ADR-005: Reference Architecture — Not Deployed to a Live Account

**Status:** Accepted  
**Date:** 2026-05-01  
**Deciders:** Kingsley Anim  

---

## Context

This repository is a portfolio piece demonstrating production-grade AWS infrastructure patterns. Fully deploying the architecture as designed would cost approximately $700–900 USD/month:

| Component | Estimated monthly cost |
|-----------|----------------------|
| EKS cluster (control plane) | ~$73 |
| EC2 managed node groups (3× m5.large) | ~$210 |
| Aurora PostgreSQL (db.r6g.large writer + reader) | ~$280 |
| NAT Gateways (3 AZs) | ~$100 |
| Load balancer, data transfer, CloudWatch | ~$80 |
| **Total** | **~$743/month** |

Running this infrastructure 24/7 purely to host a portfolio project is not economically justified. The value of the repository is in demonstrating design decisions, security patterns, and operational thinking — not in incurring cloud costs.

---

## Decision

`terraform apply` is **not** wired to auto-run on merge to `main`. The `terraform-apply.yml` workflow is configured as `workflow_dispatch` only (manual trigger via GitHub Actions UI). No live AWS account is connected to this repository.

The CI pipeline — TFLint, Checkov, `terraform validate` — runs fully credential-less on every push. These jobs validate that the infrastructure code is syntactically correct, follows security best practices, and passes static analysis without requiring AWS API access.

---

## Consequences

- The CI badge reflects the health of the **code** (lint + validate + security scan), not a live deployment.
- Terraform state files are not stored anywhere; the S3/DynamoDB backend is defined in code but not bootstrapped.
- The `checkov` security scan skips a number of checks that are either false positives under static analysis (checkov can't resolve Terraform variable defaults when scanning modules in isolation) or architectural decisions documented with rationale in `.github/workflows/tflint-and-checkov.yml`.

---

## How to deploy this to a real AWS account

1. **Create an AWS account** (or use an existing one).

2. **Bootstrap the Terraform backend** for each environment:
   ```bash
   # For the dev environment:
   aws s3 mb s3://production-platform-tfstate-dev --region us-east-1
   aws dynamodb create-table \
     --table-name production-platform-tfstate-lock-dev \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST \
     --region us-east-1
   ```

3. **Set up OIDC trust** between GitHub Actions and AWS:
   ```bash
   # Create the OIDC provider for GitHub Actions
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com \
     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
   
   # Create the IAM role that GitHub Actions will assume
   # (trust policy should allow the specific repo and branch)
   ```

4. **Set repository variables and secrets** in GitHub:
   - `AWS_ACCOUNT_ID` — your AWS account ID (dev/staging)
   - `AWS_ACCOUNT_PROD_ID` — your production AWS account ID
   - `PAGERDUTY_SNS_ENDPOINT` — secret for P1/P2 alert routing
   - `SLACK_SNS_ENDPOINT` — secret for Slack alert routing

5. **Run the apply workflow** via GitHub Actions UI:
   - Actions → Terraform Apply → Run workflow
   - Select environment: `dev`
   - Confirm by typing `dev` in the confirmation field

6. **Promote through environments** by repeating step 5 for `staging` and `prod`.
   The `prod` job requires a GitHub environment approval gate configured in
   Settings → Environments → prod → Required reviewers.

---

## References

- [ADR-001](001-eks-over-ecs.md) — EKS over ECS
- [ADR-002](002-terraform-over-cdk.md) — Terraform over CDK
- [ADR-004](004-rds-secret-rotation.md) — RDS secret rotation trade-off
