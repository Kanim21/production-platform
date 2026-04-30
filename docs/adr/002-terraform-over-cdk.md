# ADR-002: Terraform over AWS CDK for Infrastructure as Code

**Status:** Accepted  
**Date:** 2024-01-15  
**Deciders:** Platform team  

---

## Context

We need an IaC tool to define and manage AWS resources across dev, staging, and prod environments. The two leading candidates are HashiCorp Terraform (HCL, provider-agnostic) and AWS CDK (general-purpose programming language, AWS-specific). Both are production-proven.

Key constraints: the team includes engineers with mixed cloud backgrounds (AWS, GCP, on-prem), we anticipate needing non-AWS resources (Datadog, GitHub, PagerDuty) managed alongside AWS resources, and we want CI/CD-friendly plan/apply semantics.

---

## Decision

Use Terraform with OpenTofu as a contingency path if licensing changes are material.

---

## Rationale

### Why Terraform wins

**Multi-provider ecosystem.** Our platform touches AWS resources AND: GitHub (repositories, branch protections, Actions secrets), PagerDuty (services, escalation policies), Datadog (dashboards, monitors), Cloudflare (DNS). Terraform has first-class providers for all of these. CDK is AWS-native; managing non-AWS resources requires CDK custom resources or separate tools.

**Plan/apply semantics are CI/CD-native.** `terraform plan` produces a machine-readable JSON diff that we post as a PR comment. CDK's `cdk diff` output is readable but not as amenable to automated parsing and policy checks (Checkov, OPA). The plan → review → apply flow maps directly to our PR-gated deployment workflow.

**Declarative model is easier to audit.** HCL is a data language with functions, not a general-purpose language. Reviewers can read a `.tf` file and understand exactly what resources will exist. CDK in Python/TypeScript can generate resources through loops, conditionals, and function calls that make auditing the "what will this create" question harder without running `cdk synth`.

**Ecosystem tooling.** tflint, Checkov, Infracost, Atlantis, Terragrunt, Terraform Cloud — a mature ecosystem of CLI tools integrates with Terraform's state and plan files. CDK has fewer third-party integrations.

**State portability.** Terraform state is a JSON file in S3. It can be inspected, imported, and manipulated with standard tooling. CDK stores state in CloudFormation stacks — readable but only through the CloudFormation API, and subject to CloudFormation's 500-resource-per-stack limits.

**Hiring signal.** Terraform is listed in more job postings and is more widely taught in DevOps/SRE curricula than CDK. Engineers we hire are more likely to arrive with Terraform experience.

### Why CDK almost won

CDK's biggest advantage is using a real programming language. Loop over a list of microservices and create consistent resources for each? Three lines in Python. In Terraform, you'd use `for_each` with a map — functional but more verbose. CDK also has L2/L3 constructs that encode AWS best practices (e.g., `aws_cdk.aws_rds.DatabaseCluster` handles subnet group, parameter group, and security group creation in one call).

CDK would be preferable if: the team is primarily developers (not sysadmins), the infrastructure is 100% AWS with no third-party providers, and resource count per environment exceeds what Terraform modules can cleanly express.

### HashiCorp BSL License Concern

In 2023, HashiCorp re-licensed Terraform from MPL 2.0 to BSL 1.1. This restricts using Terraform to build a product that competes with HashiCorp. For our use case (internal platform, not a product), BSL has no material impact.

OpenTofu (the Linux Foundation fork, MPL 2.0) is a drop-in replacement. We write standard HCL; switching to OpenTofu requires changing one binary. We're not locked in.

---

## Consequences

**Positive:**
- Single tool manages AWS + GitHub + PagerDuty + Datadog
- `terraform plan` output integrates cleanly with Checkov, Infracost, PR comments
- HCL is auditable by security reviewers unfamiliar with Python/TypeScript
- State file is a portable JSON blob, not tied to a vendor API

**Negative:**
- HCL is less expressive than a general-purpose language; complex module abstractions get verbose
- No type safety (CDK TypeScript catches config errors at compile time; Terraform catches them at plan time)
- BSL license, though not material for our use case, adds vendor-risk to track

**Mitigations:**
- Use Terraform modules to encapsulate repeated patterns; avoid copy-paste
- Run `tflint` with the AWS ruleset to catch common configuration errors before plan
- OpenTofu is a ready fallback if BSL becomes a concern

---

## Alternatives Considered

| Option | Rejected Because |
|---|---|
| AWS CDK (Python) | AWS-only; CDK diff less CI/CD-native; harder to audit complex constructs |
| AWS CDK (TypeScript) | Same as above |
| Pulumi | Smaller ecosystem than Terraform; similar multi-language tradeoffs as CDK |
| CloudFormation | Verbose YAML; 500-resource stack limit; no multi-provider |
| Ansible for infra | Better suited for config management than resource provisioning |
