# Runbook: Ingress Degraded (ALB 5xx Spike)

**Severity:** P2 (< 5% error rate) / P1 (> 5% error rate or checkout unavailable)  
**Alert:** `IngressHighErrorRate`, `ALBTargetResponseTime`  
**Owner:** Platform on-call  

---

## Alert Conditions

| Alert | Threshold | Meaning |
|---|---|---|
| `IngressHighErrorRate` | HTTP 5xx > 1% over 5m | Backend errors reaching users |
| `ALBTargetResponseTime` | p99 > 2s over 5m | Latency degradation |
| `ALBUnhealthyHostCount` | > 0 for 10m | Targets failing health checks |
| `ALBActiveConnectionCount` | > 5000 | Connection saturation (scale may be needed) |

---

## Quick Orientation

Ingress path: `CloudFront → ALB → Target Group → EKS Pod → (Postgres / Redis)`

5xx errors can originate at any layer. Work backwards from the ALB.

```bash
# 1. Where are errors occurring? (ALB layer vs. pod layer)
# ALB 5xx includes: 502 (backend gateway error), 503 (no healthy targets), 504 (timeout)

# Get ALB metrics for last 30 minutes
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_ELB_5XX_Count \
  --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Sum --output table

# vs. target (pod) errors
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Sum --output table
```

- **ELB 5xx but no Target 5xx** → ALB can't reach pods (no healthy targets, connection refused)
- **Target 5xx** → Pods are returning errors (DB down, bug in code, OOM)
- **Both** → Likely a bad deploy or upstream dependency failure

---

## Scenario 1: No Healthy Targets (503)

```bash
# Check target health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --query 'TargetGroups[?contains(TargetGroupName, `api`)].TargetGroupArn' \
    --output text) \
  --query 'TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}'
```

**All targets unhealthy:**
```bash
# Are pods running?
kubectl get pods -n app -l app=api

# Are pods passing their own health check?
API_POD=$(kubectl get pods -n app -l app=api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n app $API_POD -- curl -s localhost:8080/health

# Check pod logs for startup errors
kubectl logs -n app $API_POD --tail=100
kubectl logs -n app $API_POD --previous 2>/dev/null | tail=50
```

**If pods are in CrashLoopBackOff — likely a bad deploy:**
```bash
# Check what changed
kubectl rollout history deployment/api -n app

# Rollback immediately
kubectl rollout undo deployment/api -n app

# Verify rollback
kubectl rollout status deployment/api -n app
```

**If pods are Running but health check fails:**
```bash
# Check what the health endpoint returns
kubectl exec -n app $API_POD -- curl -v localhost:8080/health

# Check if DB connectivity is the issue
kubectl exec -n app $API_POD -- curl -s localhost:8080/health/ready
# readiness probe checks DB; liveness probe checks process only
```

---

## Scenario 2: Targets Healthy but High 5xx Rate (Application Errors)

```bash
# Sample recent error logs
kubectl logs -n app -l app=api --tail=200 | grep -E '"level":"error"|"status":5'

# Check error rate by endpoint (Prometheus)
# PromQL: sum by(path) (rate(http_requests_total{status=~"5.."}[5m]))
```

**Database errors in logs:**
→ Follow [RDS Failover runbook](rds-failover.md)

**Timeout errors (`context deadline exceeded`):**
```bash
# Check pod CPU/memory — is it resource-starved?
kubectl top pods -n app

# Check HPA — is it trying to scale but failing?
kubectl describe hpa api-hpa -n app

# Check node capacity
kubectl top nodes
kubectl describe nodes | grep -A5 'Allocated resources'
```

If nodes are at capacity and HPA can't scale:
```bash
# Temporarily increase node group size
aws eks update-nodegroup-config \
  --cluster-name production-platform-prod \
  --nodegroup-name api-nodes \
  --scaling-config minSize=4,maxSize=20,desiredSize=6
```

**Upstream dependency errors (Redis, external API):**
```bash
# Check Redis connectivity
kubectl exec -n app $API_POD -- \
  redis-cli -h $REDIS_HOST -p 6379 ping

# Check external API call logs
kubectl logs -n app -l app=api --tail=500 | grep -i "timeout\|refused\|external"
```

---

## Scenario 3: High Latency (p99 > 2s, No Errors)

```bash
# Get response time percentiles from Prometheus
# PromQL: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# Check if specific endpoints are slow
# PromQL: sum by(path) (rate(http_request_duration_seconds_sum[5m])) 
#       / sum by(path) (rate(http_request_duration_seconds_count[5m]))
```

**DB query latency (most common cause):**
```bash
kubectl exec -n app $API_POD -- \
  psql $DATABASE_URL -c \
  "SELECT query, mean_exec_time, calls, total_exec_time
   FROM pg_stat_statements 
   ORDER BY mean_exec_time DESC 
   LIMIT 10"

# Long-running queries
kubectl exec -n app $API_POD -- \
  psql $DATABASE_URL -c \
  "SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
   FROM pg_stat_activity
   WHERE (now() - pg_stat_activity.query_start) > interval '5 seconds'"
```

Kill a blocking query (replace PID):
```bash
kubectl exec -n app $API_POD -- \
  psql $DATABASE_URL -c "SELECT pg_cancel_backend(<pid>)"
```

---

## Scenario 4: CloudFront Returning Errors (Origin Unreachable)

```bash
# Get CloudFront error rates (console or CLI)
aws cloudwatch get-metric-statistics \
  --namespace AWS/CloudFront \
  --metric-name 5xxErrorRate \
  --dimensions Name=DistributionId,Value=<cf-dist-id> \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Average --output table
```

If CloudFront can't reach the ALB (502 from CloudFront):
- Verify ALB security group allows CloudFront IP ranges (should be managed by WAF/prefix list)
- Verify ALB is in the correct VPC and has public-facing listener on 443
- Check CloudFront origin configuration (protocol, port, path)

**Emergency: Bypass CloudFront to confirm ALB is healthy:**
```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `production-platform`)].DNSName' \
  --output text)
curl -I https://$ALB_DNS/health --resolve api.production-platform.com:443:$(dig +short $ALB_DNS | head -1)
```

---

## Load Shedding (last resort)

If the system is overloaded and cascading:

```bash
# Enable maintenance mode: return 503 with Retry-After to all non-health requests
# This requires the API to have a maintenance mode env var
kubectl set env deployment/api -n app MAINTENANCE_MODE=true

# OR: scale down problematic deployment temporarily, fix, redeploy
kubectl scale deployment/api -n app --replicas=0
# (This will 503 all traffic — only for catastrophic scenarios)
```

---

## Post-Incident Checklist

- [ ] Error window duration recorded (from first 5xx to recovery)
- [ ] Root cause confirmed (bad deploy / DB / resource saturation / upstream dependency)
- [ ] SLO burn calculated: `error_minutes / total_minutes_in_window * 100`
- [ ] Rollback or fix deployed and verified stable for 15 minutes
- [ ] Alert thresholds reviewed — did we get alerted too late or too early?
- [ ] Runbook updated with any new failure modes discovered
- [ ] If > 5 minute P1: post-mortem scheduled within 48 hours
