# Security Policy

## Supported Versions

This is a reference platform. The `main` branch is the only actively maintained version.

| Version | Supported |
|---|---|
| `main` branch | Yes |
| Older snapshots / forks | No |

## Reporting a Vulnerability

If you discover a security issue — insecure Terraform patterns, hard-coded credentials, misconfigured IAM policies, or exposed secrets — please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

### How to report

Use [GitHub private vulnerability reporting](https://github.com/Kanim21/production-platform/security/advisories/new) to open a confidential advisory.

Include:
- Description of the vulnerability and potential impact
- Steps to reproduce or proof of concept (if applicable)
- Affected file(s) and line numbers
- Suggested remediation if known

### Response timeline

| Action | Target |
|---|---|
| Acknowledge receipt | 48 hours |
| Initial assessment | 5 business days |
| Fix or mitigation published | 30 days for critical/high severity |

## Security Design Principles

This platform is designed with the following security foundations — see [README Security Posture](README.md#security-posture) for details:

- **No static AWS credentials** — GitHub Actions uses OIDC; pods use IRSA
- **Secrets Manager for all secrets** — no plaintext in Terraform state, env vars, or ConfigMaps
- **Private subnets for all compute** — EKS nodes and RDS have no public IPs
- **Database subnets are air-gapped** — no NAT gateway, no internet route; security group permits only the EKS node security group
- **IMDSv2 enforced** on all EC2 nodes — hop limit=1 blocks SSRF-based metadata theft
- **tflint + Checkov** run on every PR — policy violations block merge
- **ECR image scanning** on push — critical CVEs alert before deployment
