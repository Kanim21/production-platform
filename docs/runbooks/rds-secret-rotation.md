# Runbook: RDS Master Secret — Manual Rotation

**Applies to:** Aurora PostgreSQL master credentials (Secrets Manager secret: `<env>/db-credentials`)
**Trigger:** Every 90 days, suspected credential leak, or team-member offboarding
**Related ADR:** [ADR-004 — RDS secret rotation trade-off](../adr/004-rds-secret-rotation.md)
**Escalation:** Database on-call

---

## Why this runbook exists

Auto-rotation via Lambda is deferred (see ADR-004). Until it is wired up, credential rotation is a manual procedure. This runbook is the stopgap.

---

## Pre-conditions

- AWS CLI configured with a role that has:
  - `secretsmanager:GetSecretValue`, `secretsmanager:PutSecretValue`, `secretsmanager:GetRandomPassword`
  - `rds:ModifyDBCluster`, `rds:DescribeDBClusters`
- Aurora cluster identifier (check `terraform output` or AWS Console → RDS)
- `jq` installed locally
- Low-traffic window scheduled for prod (rotation causes a brief connection reset on next reconnect)

---

## Steps

### 1. Generate a new password

```bash
NEW_PASSWORD=$(aws secretsmanager get-random-password \
  --password-length 32 \
  --exclude-characters '"@/\' \
  --require-each-included-type \
  --query 'RandomPassword' --output text)

echo "Password generated (length: ${#NEW_PASSWORD})"
# Do NOT echo the password itself to a terminal that is being recorded
```

### 2. Update the Aurora master password

```bash
ENV="prod"                    # dev | staging | prod
CLUSTER_ID="${ENV}-aurora"

aws rds modify-db-cluster \
  --db-cluster-identifier "$CLUSTER_ID" \
  --master-user-password "$NEW_PASSWORD" \
  --apply-immediately

echo "Waiting for cluster to become available..."
aws rds wait db-cluster-available --db-cluster-identifier "$CLUSTER_ID"
echo "Aurora password updated."
```

### 3. Update the Secrets Manager secret

```bash
SECRET_NAME="${ENV}/db-credentials"

CURRENT=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --query 'SecretString' --output text)

UPDATED=$(echo "$CURRENT" | jq --arg p "$NEW_PASSWORD" '.password = $p')

aws secretsmanager put-secret-value \
  --secret-id "$SECRET_NAME" \
  --secret-string "$UPDATED"

echo "Secret updated."
```

### 4. Verify connectivity

Exec into a running API pod and verify the application connects with the new credential:

```bash
POD=$(kubectl get pod -l app=api -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it "$POD" -- sh -c \
  'DB_PASS=$(aws secretsmanager get-secret-value \
    --secret-id $DB_SECRET_ARN --query SecretString --output text | jq -r .password) && \
   PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1 AS ok;"'
```

Expected: `ok = 1`. If connection is refused, see **Rollback** below.

### 5. Rolling restart pods

Pods read the secret at startup via IRSA + External Secrets Operator. Trigger a rolling restart:

```bash
kubectl rollout restart deployment/api
kubectl rollout status deployment/api --timeout=5m
```

Monitor for errors during the rollout:
```bash
kubectl logs -l app=api --since=2m -f | grep -i "error\|fail\|connect"
```

### 6. Record the rotation

Log in your ops wiki / ticket:
- Date and time
- Operator name
- Ticket or incident reference
- Environment rotated

Do **not** record the password itself anywhere.

---

## Rollback

**If step 2 fails after 3 minutes:**
The old password is still active — Aurora does not apply the change until `db-cluster-available`. Retrieve the original password from Secrets Manager (the secret has not been updated yet) and re-run step 2 with the original value.

**If pods fail to start after step 5:**
```bash
kubectl rollout undo deployment/api
kubectl rollout status deployment/api
```

Then compare the secret JSON (host, port, dbname fields) against what the pod environment expects — a prior manual edit may have caused drift.

**If Aurora password and secret are out of sync:**
Do not guess which value is authoritative. Escalate to database on-call immediately. Attempting both steps without knowing which password Aurora currently accepts can lock out the application entirely.

---

## Verification checklist

- [ ] `aws rds describe-db-clusters` shows `Status: available`
- [ ] Secrets Manager secret shows a new `AWSCURRENT` version with today's date
- [ ] All API pods reached `Running` after restart
- [ ] No 5xx spike in Grafana API dashboard for 10 minutes post-rotation
- [ ] Rotation event recorded in ops wiki

---

## Next steps

When capacity allows, implement the AWS SAR rotation function per [ADR-004](../adr/004-rds-secret-rotation.md) to eliminate this manual procedure.
