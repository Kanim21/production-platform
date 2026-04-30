# ADR-001: EKS over ECS for Container Orchestration

**Status:** Accepted  
**Date:** 2024-01-15  
**Deciders:** Platform team  

---

## Context

We need a container orchestration platform for a multi-service e-commerce backend. The two primary AWS-native options are ECS (Elastic Container Service) and EKS (Elastic Kubernetes Service). Both are production-proven at scale. This decision affects hiring, tooling, operational patterns, and long-term portability.

The workload is: 4–6 microservices, mixed on-demand and batch workloads, need for fine-grained resource control, and a team that will grow from 3 to ~15 engineers over 18 months.

---

## Decision

Use EKS with managed node groups.

---

## Rationale

### Why EKS wins for this workload

**Portability and hiring.** Kubernetes is the de facto container orchestration standard. Engineers joining from other companies arrive with transferable kubectl/Helm skills. ECS knowledge is AWS-only — every ECS engineer had to learn it specifically for AWS.

**Ecosystem breadth.** The Kubernetes ecosystem has solutions for every operational problem we'll encounter: Argo CD for GitOps, Keda for event-driven autoscaling, External Secrets Operator for secrets injection, Crossplane for infrastructure provisioning. ECS relies on AWS-proprietary equivalents or custom solutions.

**Resource model expressiveness.** Kubernetes resource requests/limits, LimitRanges, PriorityClasses, and PodDisruptionBudgets give fine-grained control over bin-packing and disruption handling. ECS task placement strategies are simpler but less expressive when you need to enforce per-service resource guarantees.

**Horizontal Pod Autoscaling + KEDA.** We need event-driven scaling for order processing (scale on SQS depth) and memory-based scaling for the catalog cache. KEDA handles both. ECS Application Auto Scaling covers CPU/memory but requires custom CloudWatch metrics for SQS-based scaling.

**Multi-tenancy model.** Kubernetes namespaces + RBAC give a clear isolation boundary between services (dev team A cannot see service B's secrets). ECS task definitions don't have an equivalent namespace model.

### Why ECS almost won

ECS is operationally simpler. There's no control plane to think about (AWS manages ECS for free; EKS costs $72/month per cluster). ECS Fargate removes node management entirely. For teams without existing Kubernetes expertise, ECS can be a better starting point.

ECS with Fargate would be preferable if: the team has no Kubernetes experience, the service count stays below ~5, and there's no need for custom schedulers or ecosystem tooling.

### Why not ECS Fargate specifically

Fargate removes node management but introduces constraints that matter for us:
- No DaemonSets (we need node-exporter and Fluent Bit on every node)
- Higher per-vCPU-hour cost than EC2 (~20–30% premium)
- No GPU support (irrelevant now, but we have a recommendation model in the roadmap)
- EFS required for any persistent volumes (EBS not supported on Fargate)

---

## Consequences

**Positive:**
- Engineers can transfer Kubernetes skills from/to other employers and projects
- Full Helm ecosystem available for off-the-shelf operational tooling
- Clear upgrade path to multi-cluster, multi-region, or hybrid-cloud topologies

**Negative:**
- EKS cluster costs $72/month (control plane), regardless of node count
- Kubernetes has a steeper learning curve; new engineers need onboarding time
- Managed node group upgrades require a drain-and-replace cycle; Fargate would be transparent
- We own node-level security patching (AMI updates) — ECS Fargate patches are AWS-managed

**Mitigations:**
- Managed node groups reduce upgrade friction vs. self-managed nodes
- Terraform automation handles AMI updates via node group update policy
- kube-prometheus-stack gives immediate visibility into cluster health during upgrades

---

## Alternatives Considered

| Option | Rejected Because |
|---|---|
| ECS + EC2 | Less ecosystem tooling; ECS task placement is less expressive than k8s scheduling |
| ECS Fargate | No DaemonSets; higher cost per vCPU; GPU not supported |
| Self-managed k8s (kops) | Control plane operational burden not justified when EKS exists |
| Nomad | Smaller ecosystem; HashiCorp's pivot to BSL license creates long-term risk |
