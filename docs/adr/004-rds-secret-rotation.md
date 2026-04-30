# ADR-004: RDS Secret Auto-Rotation — Deferred to Post-Scaffold

**Date:** 2026-04-30
**Status:** Accepted

---

## Context

Aurora PostgreSQL master credentials are stored in AWS Secrets Manager (KMS-encrypted, read access scoped to the API pod service account via IRSA). Auto-rotation is the production-correct posture — it minimises the breach window if a credential is ever exfiltrated.

Implementing auto-rotation requires a Lambda function that:
1. Runs inside the VPC (to reach the Aurora endpoint on port 5432)
2. Has a VPC endpoint or NAT route to reach the Secrets Manager API
3. Contains the actual rotation logic (generate → set on Aurora → update secret version → test connectivity)

AWS provides a pre-built rotation function for this exact pattern via the [Serverless Application Repository (SAR)](https://serverlessrepo.aws.amazon.com/applications/arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser).

The initial scaffold included a placeholder `aws_lambda_function` resource pointing to a `rotation_placeholder.zip` artifact that does not exist on disk. This caused:
- `terraform apply` to fail at plan time with a `filebase64sha256` read error
- A false impression that auto-rotation was configured and operational

---

## Decision

Remove the placeholder Lambda and the `aws_secretsmanager_secret_rotation` resource. The Secrets Manager secret and KMS key remain. The password is generated securely (32-char random, special characters, KMS-encrypted). Auto-rotation is deferred; manual rotation is documented in the [rds-secret-rotation runbook](../runbooks/rds-secret-rotation.md).

---

## Consequences

**Positive:**
- `terraform apply` succeeds without a pre-existing artifact dependency
- The actual security posture is accurately represented in code — no phantom "rotation is running" claim
- Simpler module surface for portfolio demonstration

**Negative:**
- Credentials do not rotate automatically; the breach window equals the credential lifetime
- Manual rotation requires human execution of the runbook — operator error risk exists

**Accepted risk:** For a portfolio reference platform this trade-off is acceptable. For production, auto-rotation is required.

---

## Recommended Production Implementation

Use the AWS SAR pre-built function, which handles the Aurora PostgreSQL single-user rotation correctly (including the multi-step AWSPENDING → AWSCURRENT secret version lifecycle):

```hcl
data "aws_region" "current" {}

resource "aws_serverlessapplicationrepository_cloudformation_stack" "rds_rotator" {
  name           = "${var.name}-secret-rotator"
  application_id = "arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser"
  capabilities   = ["CAPABILITY_IAM", "CAPABILITY_RESOURCE_POLICY"]

  parameters = {
    endpoint            = "https://secretsmanager.${data.aws_region.current.name}.amazonaws.com"
    functionName        = "${var.name}-secret-rotation"
    vpcSubnetIds        = join(",", var.private_subnet_ids)
    vpcSecurityGroupIds = aws_security_group.aurora.id
  }
}

resource "aws_secretsmanager_secret_rotation" "db_credentials" {
  secret_id           = aws_secretsmanager_secret.db_credentials.id
  rotation_lambda_arn = aws_serverlessapplicationrepository_cloudformation_stack.rds_rotator.outputs["RotationLambdaARN"]

  rotation_rules {
    automatically_after_days = 30
  }
}
```

**Prerequisites not in scope for this scaffold:**
- A Secrets Manager VPC endpoint (or NAT route from the Lambda subnet) so the rotation function can reach the Secrets Manager API without traversing the internet
- The `private_subnet_ids` variable wired through the RDS module inputs
- IAM permission for `serverlessrepo:CreateCloudFormationTemplate` in the Terraform deployment role

---

## Alternatives Considered

| Option | Why rejected |
|---|---|
| Ship the placeholder ZIP with stub code | Rotation would "run" but silently fail — worse than no rotation because it gives false confidence |
| Custom rotation Lambda (hand-rolled) | Re-implementing what AWS already provides in SAR adds maintenance burden with no benefit |
| AWS-managed rotation (native, no Lambda) | Available for RDS managed passwords; not compatible with Aurora clusters where `master_password` is set via Terraform |
