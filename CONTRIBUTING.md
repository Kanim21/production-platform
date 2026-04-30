# Contributing

## Branching

Branch from `main` using a descriptive prefix:

| Prefix | Use |
|---|---|
| `feat/` | New functionality |
| `fix/` | Bug fix |
| `docs/` | Documentation only |
| `chore/` | Dependency bumps, tooling |
| `refactor/` | Code restructuring, no behaviour change |

Delete branches after merge.

## Commit conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(eks): add Karpenter node provisioner
fix(rds): remove broken rotation placeholder
docs(adr): add ADR-004 for secret rotation trade-off
chore(deps): bump aws provider to 5.50
```

**Types:** `feat` · `fix` · `docs` · `chore` · `refactor` · `test` · `ci`

**Scope** (optional): module or subsystem — `eks`, `rds`, `vpc`, `monitoring`, `ci`, `adr`

Keep the subject line under 72 characters. Use the body for *why*, not *what*.

## Local checks before pushing

```bash
# Terraform format
terraform fmt -recursive terraform/

# Validate all environments
make validate

# Lint
make lint

# Security scan
make checkov
```

All checks must pass locally before pushing. CI will block PRs that fail any of them.

## Pull request checklist

- [ ] Branch is up to date with `main`
- [ ] `make lint` and `make validate` pass locally
- [ ] `make checkov` passes (or violations are documented with inline suppressions and justification)
- [ ] New Terraform resources include a `tags` block
- [ ] ADR added or updated if an architectural decision was made
- [ ] Runbook added or updated if operational behaviour changed
- [ ] PR description explains *why* the change is needed, not just *what* changed

## Environment promotion

`dev` → `staging` (automatic on merge to `main`) → `prod` (manual approval gate in GitHub Actions)

Never push directly to a live environment. All changes flow through PR → CI → merge → promotion pipeline.
