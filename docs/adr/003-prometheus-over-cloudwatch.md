# ADR-003: Prometheus Stack over CloudWatch-Only Observability

**Status:** Accepted  
**Date:** 2024-01-22  
**Deciders:** Platform team, on-call rotation members  

---

## Context

We need a metrics and alerting stack for the platform. AWS provides CloudWatch as a native service. The alternative is the open-source kube-prometheus-stack (Prometheus + Alertmanager + Grafana), which we'd run in-cluster. This isn't an either/or — we use both — but the question is: which is the primary alert/query surface for incident response?

This decision is shaped by a concrete pain point: in the previous organization, all observability ran through CloudWatch. During a 2am incident, CloudWatch Metrics Insights queries were taking 15–30 seconds to return. Prometheus queries on the same data returned in under 100ms.

---

## Decision

Run kube-prometheus-stack as the primary observability stack. Ship logs to CloudWatch for compliance and long-term retention. CloudWatch alarms are used only for AWS-managed service health (RDS, ALB, NAT Gateway) where Prometheus cannot scrape metrics directly.

---

## Rationale

### Prometheus advantages

**Query latency during incidents.** PromQL queries against in-cluster Prometheus return in < 100ms. CloudWatch Metrics Insights queries on the same cardinality return in 5–30 seconds. During an incident, the difference between 100ms and 15s per query is the difference between confirming a hypothesis in 5 minutes vs. 20 minutes. This is the primary driver.

**Cardinality and labels.** Prometheus handles high-cardinality metric labels natively. CloudWatch Metrics has dimension limits (30 dimensions per metric, 10 metrics per alarm). Labeling every metric by `pod`, `namespace`, `service`, `version`, and `customer_tier` is trivial in Prometheus and approaches CloudWatch limits.

**Kubernetes-native integration.** kube-prometheus-stack ships ServiceMonitor and PodMonitor CRDs. Adding metrics collection for a new service is one Kubernetes manifest, not a CloudWatch agent configuration change. The operator handles scrape target discovery automatically.

**Grafana dashboards.** Grafana with Prometheus data source gives dashboards that auto-update as new pods/nodes join the cluster. CloudWatch dashboards require manual widget configuration or CloudFormation templates.

**Alertmanager routing.** Alertmanager gives fine-grained alert routing: P1 alerts go to PagerDuty + Slack oncall channel; P2 go to Slack only; P3 go to a weekly digest. CloudWatch Alarms route to SNS topics, and building equivalent routing logic requires Lambda functions or custom infrastructure.

**Cost.** At scale, CloudWatch custom metrics cost $0.30/metric/month. At 1,000 custom metrics (realistic for a 5-service Kubernetes cluster with per-pod metrics), that's $300/month in metrics costs alone. Prometheus is free (compute cost is already paid for by EKS nodes).

### CloudWatch advantages we're not giving up

We still use CloudWatch for:
- **RDS metrics** (CPU, connections, replication lag) — scraped via CloudWatch Exporter sidecar into Prometheus
- **ALB access logs** — shipped to S3 via CloudWatch Logs; queried with Athena for ad-hoc analysis
- **Container logs** — Fluent Bit ships all pod logs to CloudWatch Logs for 365-day retention and compliance
- **AWS-managed service alarms** — NAT Gateway packet drop, EKS API server latency are CloudWatch-native and complement Prometheus

### Operational overhead of running Prometheus in-cluster

The main cost of this decision is that we own the Prometheus deployment. This means:
- PVC for Prometheus data (50 GB, `gp3`)
- Prometheus upgrade cadence (kube-prometheus-stack Helm chart releases)
- Storage capacity planning (30-day retention at current cardinality ≈ 50 GB)
- HA configuration (two Prometheus replicas with `deduplicateLabels` in Thanos or VictoriaMetrics for long-term storage — phase 2)

For phase 1 (scaffold), we run a single Prometheus instance. Loss of the Prometheus pod means no metric queries until rescheduled (~2 minutes). Alertmanager continues to fire in-flight alerts. This is acceptable for a platform serving 10k concurrent users; we'd add Thanos or VictoriaMetrics before 100k.

---

## Consequences

**Positive:**
- Sub-100ms query latency during incidents
- No CloudWatch custom metric costs for Kubernetes workload metrics
- Kubernetes-native service discovery; zero manual configuration per new service
- Alertmanager gives sophisticated routing without Lambda glue

**Negative:**
- We own the Prometheus/Grafana deployment and upgrade cycle
- Single Prometheus instance is a SPOF for metrics queries (mitigated: alerts continue to fire via Alertmanager)
- Grafana credential management (we use AWS SSO integration via Grafana SAML in prod)
- Engineers unfamiliar with PromQL have a learning curve

**Mitigations:**
- kube-prometheus-stack Helm chart handles most operational complexity
- Grafana dashboards are committed to git (Grafana's dashboard provisioning from ConfigMaps)
- PromQL basics training is a 2-hour investment; oncall runbooks include example queries

---

## Alternatives Considered

| Option | Rejected Because |
|---|---|
| CloudWatch only | 5–30s query latency; high cardinality limits; expensive at scale; alert routing requires Lambda |
| Datadog | $15–23/host/month at our node count = ~$500/mo; vendor lock-in; equivalent capability |
| New Relic | Similar cost profile to Datadog; Prometheus is free and equally capable |
| Thanos from day 1 | Overengineered for current scale; adds 3 more components to operate; revisit at 100k users |
| VictoriaMetrics | Drop-in Prometheus replacement with better performance; valid option, chose kube-prometheus-stack for community size |
