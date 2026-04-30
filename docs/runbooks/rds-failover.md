# Runbook: Aurora PostgreSQL Failover

**Severity:** P1 during failover window (~30s) / P2 for elevated latency  
**Alert:** `RDSHighConnectionCount`, `RDSReplicationLag`, `RDSAuroraFailoverStarted`  
**Owner:** Platform on-call  

---

## How Aurora Failover Works

Aurora uses shared distributed storage. The reader replica already has access to the full dataset — there's nothing to replicate during failover. When Aurora promotes a reader to writer:

1. The current writer loses quorum (or is explicitly failed over)
2. Aurora promotes the reader replica in < 30s (typically 15–20s)
3. The **cluster endpoint** DNS record is updated to point at the new writer
4. The **reader endpoint** DNS record updates to point at remaining replicas
5. TCP connections to the old writer are dropped; application reconnect logic takes over

**Application impact:** ~15–30s of connection errors followed by automatic reconnection. Our API's reconnect logic uses exponential backoff with jitter (max wait: 30s, max retries: 10).

---

## Impact Assessment

```bash
# Check RDS cluster status
aws rds describe-db-clusters \
  --db-cluster-identifier production-platform-prod \
  --query 'DBClusters[0].{Status:Status,Members:DBClusterMembers}'

# Check which instance is the current writer
aws rds describe-db-clusters \
  --db-cluster-identifier production-platform-prod \
  --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier'

# Is the API returning database errors? Check Prometheus
# Query: rate(http_requests_total{status=~"5.."}[5m]) > 0.01
```

---

## Scenario 1: Aurora Auto-Failover in Progress

**Signs:** Alert fires, API returns 5xx for < 60s, then recovers.

1. Confirm failover completed:
   ```bash
   aws rds describe-events \
     --source-identifier production-platform-prod \
     --source-type db-cluster \
     --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
     --query 'Events[*].{Time:Date,Message:Message}'
   ```
2. Verify new writer is healthy:
   ```bash
   aws rds describe-db-instances \
     --query 'DBInstances[?DBClusterIdentifier==`production-platform-prod`].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Role:ReadReplicaSourceDBInstanceIdentifier}'
   ```
3. Check API error rate has returned to baseline (Grafana → API dashboard)
4. No further action needed. File incident report if error window > 60s.

---

## Scenario 2: Extended Outage (> 2 Minutes of DB Errors)

If the API is still returning 5xx after 2 minutes, the cluster did not automatically recover.

### Step 1: Check cluster health

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier production-platform-prod \
  --query 'DBClusters[0].Status'
# Expected: "available"
# If "failing-over": wait, it's still in progress
# If "migration-failed" or any error state: proceed to manual steps
```

### Step 2: Force failover if primary is stuck

```bash
# This initiates a failover to the healthiest replica
aws rds failover-db-cluster \
  --db-cluster-identifier production-platform-prod

# Watch status (poll every 10s)
watch -n 10 'aws rds describe-db-clusters \
  --db-cluster-identifier production-platform-prod \
  --query "DBClusters[0].{Status:Status,Writer:DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier|[0]}"'
```

### Step 3: Verify application connectivity

```bash
# Exec into an API pod and test DB connection
API_POD=$(kubectl get pods -n app -l app=api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n app $API_POD -- \
  psql $DATABASE_URL -c "SELECT 1"
```

If the API can't connect after failover completes:

```bash
# Check if the API is using the cluster endpoint (not a specific instance endpoint)
kubectl get secret -n app db-credentials -o jsonpath='{.data.host}' | base64 -d
# Must be the cluster endpoint: production-platform-prod.cluster-xxxx.us-east-1.rds.amazonaws.com
# NOT an instance endpoint like: production-platform-prod-instance-1.xxxx.us-east-1.rds.amazonaws.com
```

If using an instance endpoint: update the secret and roll the deployment:
```bash
CLUSTER_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier production-platform-prod \
  --query 'DBClusters[0].Endpoint' --output text)

aws secretsmanager update-secret \
  --secret-id production-platform/prod/db-credentials \
  --secret-string "{\"host\":\"$CLUSTER_ENDPOINT\",\"port\":5432,\"dbname\":\"platform\"}"

kubectl rollout restart deployment/api -n app
```

---

## Scenario 3: Storage Layer Issue (Rare)

Aurora storage is replicated 6 ways across 3 AZs. A storage-level failure requires AWS intervention. If `aws rds describe-events` shows storage errors:

1. Open an AWS Support case (severity: production down)
2. Evaluate Point-in-Time Recovery:
   ```bash
   # Restore to 5 minutes before the incident
   RESTORE_TIME=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
   
   aws rds restore-db-cluster-to-point-in-time \
     --db-cluster-identifier production-platform-prod-restored \
     --source-db-cluster-identifier production-platform-prod \
     --restore-to-time $RESTORE_TIME \
     --vpc-security-group-ids sg-xxxx \
     --db-subnet-group-name production-platform-prod
   ```
3. Update the cluster endpoint in Secrets Manager to the restored cluster
4. Data between restore time and incident time is lost — communicate to stakeholders

---

## Connection Count Alert (`RDSHighConnectionCount` > 400)

Max connections for `db.r7g.large` is ~500 (default parameter group). At 400 connections, we're in danger of exhaustion.

```bash
# Check which apps are holding connections
kubectl exec -n app $API_POD -- \
  psql $DATABASE_URL -c \
  "SELECT application_name, count(*) FROM pg_stat_activity GROUP BY 1 ORDER BY 2 DESC"
```

Short-term mitigation:
```bash
# Kill idle connections older than 5 minutes
kubectl exec -n app $API_POD -- \
  psql $DATABASE_URL -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity 
   WHERE state = 'idle' AND state_change < now() - interval '5 minutes'"
```

Long-term fix: deploy RDS Proxy (connection pooler) — this is in the phase-2 roadmap.

---

## Replication Lag Alert

```bash
# Check replica lag
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name AuroraReplicaLag \
  --dimensions Name=DBClusterIdentifier,Value=production-platform-prod \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Maximum \
  --query 'Datapoints[*].{Time:Timestamp,Lag:Maximum}' \
  --output table
```

Replica lag > 100ms: check for long-running transactions on the writer.
Replica lag > 1s: stop routing read queries to the replica endpoint until lag clears.

---

## Post-Incident Checklist

- [ ] Failover duration recorded (from first alert to API recovery)
- [ ] Root cause identified (EC2 host failure, storage issue, network partition)
- [ ] Reconnect logic confirmed working (check API error rate graph, verify recovery was automatic)
- [ ] AWS RDS event log exported to incident ticket
- [ ] If > 60s impact: SLO burn calculated and recorded
- [ ] Runbook updated if gaps were found
