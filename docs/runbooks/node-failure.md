# Runbook: EKS Node Failure

**Severity:** P2 (single node) / P1 (multiple nodes, pod count below PDB)  
**Alert:** `KubeNodeNotReady` or `KubeNodeUnreachable`  
**Owner:** Platform on-call  

---

## Impact Assessment

Before taking action, determine the scope:

```bash
# How many nodes are NotReady?
kubectl get nodes | grep -v Ready

# Are there pods in a bad state?
kubectl get pods -A | grep -Ev 'Running|Completed'

# Is the API serving traffic? Check ALB target health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --query 'TargetGroups[?contains(TargetGroupName, `api`)].TargetGroupArn' \
    --output text)
```

**If ALB targets are healthy and API is serving:** This is an automated recovery — monitor for 10 minutes. Cluster Autoscaler will replace the node.

**If pods are Pending and no healthy API targets:** Escalate to P1. Proceed immediately.

---

## Automated Recovery (most cases)

EKS managed node groups handle single-node failures automatically:

1. EKS detects the node is unhealthy (kubelet stops responding)
2. Cluster Autoscaler or the managed node group health check terminates the EC2 instance
3. ASG launches a replacement instance (same AMI, same AZ)
4. Node registers with the cluster (~3–5 minutes)
5. Pods reschedule onto the new node
6. ALB target group registers the new pod endpoints

**Expected resolution time:** 5–10 minutes without intervention.

---

## Manual Steps (if automated recovery stalls)

### Step 1: Identify the failed node and instance

```bash
# Get the node name and instance ID
NODE_NAME=<node-from-alert>
INSTANCE_ID=$(kubectl get node $NODE_NAME \
  -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)

echo "Instance: $INSTANCE_ID"

# Check EC2 instance state
aws ec2 describe-instance-status \
  --instance-ids $INSTANCE_ID \
  --query 'InstanceStatuses[0].{State:InstanceState.Name,SystemStatus:SystemStatus.Status,InstanceStatus:InstanceStatus.Status}'
```

### Step 2: Cordon the node (prevent new pod scheduling)

```bash
kubectl cordon $NODE_NAME
```

### Step 3: Drain the node (evict existing pods gracefully)

```bash
# --grace-period=60: give pods 60s to finish in-flight requests
# --ignore-daemonsets: DaemonSet pods will be recreated automatically
kubectl drain $NODE_NAME \
  --grace-period=60 \
  --ignore-daemonsets \
  --delete-emptydir-data
```

If drain hangs (pod not terminating):
```bash
# Check which pod is stuck
kubectl get pods -A --field-selector spec.nodeName=$NODE_NAME

# Force delete if stuck > 5 min (last resort — risks data loss for stateful pods)
kubectl delete pod <stuck-pod> -n <namespace> --grace-period=0 --force
```

### Step 4: Terminate the EC2 instance

```bash
# Terminate — ASG will launch a replacement
aws ec2 terminate-instances --instance-ids $INSTANCE_ID

# Watch for replacement
watch -n 10 'kubectl get nodes'
```

### Step 5: Verify recovery

```bash
# All nodes Ready?
kubectl get nodes

# Pods running on the new node?
kubectl get pods -A | grep -v 'Running\|Completed'

# ALB targets healthy?
# (run the elbv2 command from Impact Assessment above)
```

---

## Multiple Nodes Down (AZ Failure Scenario)

If all nodes in one AZ are NotReady simultaneously, this is likely an AZ-level event:

1. **Do not attempt to replace nodes in the affected AZ** — wait for AWS to recover the AZ
2. Verify the other two AZs have sufficient capacity to run the minimum pod count per PDB:
   ```bash
   kubectl get pdb -A
   ```
3. If capacity is insufficient, temporarily increase the node group minimum:
   ```bash
   aws eks update-nodegroup-config \
     --cluster-name production-platform-prod \
     --nodegroup-name api-nodes \
     --scaling-config minSize=4,maxSize=20,desiredSize=4
   ```
4. Monitor CloudWatch / AWS Health Dashboard for AZ recovery ETA
5. Once AZ recovers, rebalance the node group:
   ```bash
   # Terminate nodes in the recovered AZ to trigger balanced replacement
   # (Cluster Autoscaler handles this automatically in ~15 min)
   ```

---

## Spot Interruption (workers node group)

Spot interruptions are handled automatically by the Node Termination Handler. You'll see:
- `SpotInterruption` event in the node's events
- Node cordoned and drained within the 2-minute notice window
- ASG launches an on-demand replacement or a Spot instance in a different pool

No manual intervention needed. If NTH is not draining properly:
```bash
kubectl get pods -n kube-system | grep node-termination
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-node-termination-handler --tail=50
```

---

## Post-Incident

1. Check if the failure was hardware (AWS system check failure) or software (OOM kill, kernel panic):
   ```bash
   # Get system logs from the failed instance (if not yet terminated)
   aws ec2 get-console-output --instance-id $INSTANCE_ID --output text
   ```
2. If OOM: check `kubectl top nodes` and `kubectl top pods` for memory pressure and adjust resource limits
3. File an incident report if > 2 nodes failed or if SLO burn was > 5 minutes
4. Update this runbook if you discovered a gap

---

## Useful Dashboards

- Grafana → **EKS Cluster Overview**: node status, pod counts, scheduling pressure
- CloudWatch → **ContainerInsights**: node-level CPU/memory
- AWS Console → EC2 → Auto Scaling Groups → `production-platform-*-api-nodes`
