# Filesystem Growth / Disk Exhaustion - OpenSearch

## Overview

This guide demonstrates how to observe **filesystem/disk growth** by flooding OpenSearch with telemetry data using feature flags and load generation - **with ZERO code changes required**.

### Use Case Summary

- **Target Service:** OpenSearch (stores all logs and traces)
- **Method:** Flood with error logs using feature flags + sustained traffic
- **Trigger Mechanism:** Multiple FlagD feature flags + Locust load generator
- **Observable Outcome:** Disk grows from ~900MB → 4-5GB in 2-3 hours
- **Pattern:** Cumulative log accumulation from error-generating flags
- **Monitoring:** Honeycomb UI + Docker/kubectl disk commands

---

## Related Scenarios

| Scenario | Target | Data Type | Growth Pattern |
|----------|--------|-----------|----------------|
| **[Filesystem Growth](filesystem-growth-crash-simple.md)** | OpenSearch | Logs/traces | Cumulative disk growth (this guide) |
| **[Postgres Disk/IOPS](postgres-disk-iops-pressure.md)** | PostgreSQL | Transactional data | Database growth + I/O pressure |

**Key Difference:** This demonstrates **log/trace data accumulation** in storage backend vs transactional database growth.

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- Docker and Docker Compose installed OR Kubernetes cluster
- Access to Honeycomb UI
- FlagD UI accessible

---

## How It Works

OpenSearch stores all logs and traces to disk. By enabling error flags and generating load, services produce large volumes of error logs that accumulate in OpenSearch storage, causing disk usage to grow from ~900MB to 4-5GB in 2-3 hours.

---

## Execution Steps:

### Step 1: Check Starting Size

**For Kubernetes:**
```bash
kubectl exec -it opensearch-0 -n otel-demo -- du -sh /usr/share/opensearch/data
```

**For Docker Compose:**
```bash
docker exec opensearch du -sh /usr/share/opensearch/data
```

You'll see something like: **~150MB to 1GB** (baseline - depends on existing data)

### Step 2: Enable Error Flags

Go to **FlagD UI** (`http://localhost:4000`):

| Flag | Setting | Effect |
|------|---------|--------|
| `kafkaQueueProblems` | `2000` | Massive Kafka logs per checkout |
| `cartFailure` | `on` | All cart ops fail with errors |
| `paymentFailure` | `100%` | All payments fail with stack traces |
| `adFailure` | `on` | Continuous error logs |

### Step 3: Generate High Traffic

**Locust** (`http://localhost:8089`):
- **Users:** `50` (if load-generator is limited)
- **Ramp up:** `5`
- **Runtime:** `120m` to `180m` (2-3 hours for observable growth)
- Click **Start**

**Note:** With 50 users, disk growth is slower but steady. Expect ~500MB-1GB per hour instead of 1-2GB/hour with higher user counts.

### Step 4: Monitor Growth

**Watch disk grow (updates every 10s):**

**For Kubernetes:**
```bash
watch -n 10 "kubectl exec opensearch-0 -n otel-demo -- du -sh /usr/share/opensearch/data"
```

**For Docker Compose:**
```bash
watch -n 10 "docker exec opensearch du -sh /usr/share/opensearch/data"
```

Expected growth with 50 users (starting from ~760MB):
```
760M  → 1.0G (15min) → 1.4G (30min) → 2.0G (60min) → 3.3G (120min) → 4.8G (180min)
```

Growth rate: **~500MB-1GB per hour** with error flags enabled.

**Check indices:**

**For Kubernetes (exec into pod):**
```bash
# List indices with sizes
kubectl exec opensearch-0 -n otel-demo -- curl -s http://localhost:9200/_cat/indices?v
```

**Example output:**
```
health status index                    docs.count store.size
yellow open   .opensearch-observability         0      208b
yellow open   otel-logs-2025-10-23         125847      1.2gb
yellow open   otel-logs-2025-10-22          98234    890.5mb
```

**Sorted by size (largest first):**
```bash
kubectl exec opensearch-0 -n otel-demo -- curl -s 'http://localhost:9200/_cat/indices?v&s=store.size:desc'
```

**For Docker Compose:**
```bash
curl http://localhost:9200/_cat/indices?v
```

**Check cluster health:**

**For Kubernetes:**
```bash
kubectl exec opensearch-0 -n otel-demo -- curl -s http://localhost:9200/_cluster/health?pretty
```

**Example output (healthy):**
```json
{
  "cluster_name" : "opensearch-cluster",
  "status" : "green",
  "number_of_nodes" : 1,
  "number_of_data_nodes" : 1,
  "discovered_master" : true,
  "active_primary_shards" : 3,
  "active_shards" : 3
}
```

**Example output (disk pressure):**
```json
{
  "cluster_name" : "opensearch-cluster",
  "status" : "yellow",  // ← Warning sign
  "number_of_nodes" : 1,
  "number_of_data_nodes" : 1
}
```

**For Docker Compose:**
```bash
curl http://localhost:9200/_cluster/health?pretty
```

**What to watch for:**
- `"status": "green"` = Healthy
- `"status": "yellow"` = Warning (disk pressure starting)
- `"status": "red"` = Critical (disk full or service degraded)

### Step 5: Monitor Growth in Honeycomb

#### A. OpenSearch Disk Usage (Primary Metric)

**Query for disk usage:**
```
WHERE k8s.pod.name = opensearch-0
VISUALIZE MAX(k8s.pod.ephemeral-storage.used)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**Alternative - Filesystem usage:**
```
WHERE k8s.pod.name = opensearch-0
VISUALIZE MAX(k8s.filesystem.usage)
GROUP BY time(30s)
TIME RANGE: Last 3 hours
```

**What to look for:**
- Steady upward trend (linear growth)
- Starting around 762MB
- Growing ~500MB-1GB per hour
- Should reach 4-5GB after 3 hours

#### B. Log Volume (Driving Disk Growth)

**Total log events per minute:**
```
WHERE service.name exists
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**With error flags enabled, should see 10-100x increase in log volume.**

#### C. Checkout Activity (Primary Driver)

**Checkouts generating logs:**
```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

Each checkout with `kafkaQueueProblems: 2000` generates ~250KB of logs.

#### D. Error Rate (More Logs)

**Errors by service:**
```
WHERE service.name exists
VISUALIZE COUNT
GROUP BY service.name, otel.status_code
TIME RANGE: Last 3 hours
```

Errors generate much more verbose logs than success.

#### E. OpenSearch Health Metrics

**Check for performance degradation:**
```
WHERE service.name = opensearch OR k8s.pod.name = opensearch-0
VISUALIZE P95(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

As disk fills, OpenSearch queries slow down.

---

## Expected Timeline (50 Users)

| Time | Data Size | Status |
|------|-----------|--------|
| 0m | 150MB | Baseline |
| 30m | 600MB | Growing |
| 60m | 1.2GB | Steady growth |
| 120m | 2.5GB | Yellow health possible |
| 180m | 4GB+ | Disk pressure |
| 240m | 5-6GB | May hit limits |

**With 50 users, you need to run 2-4 hours to see significant disk growth.**

**To reset:** Just restart the pod/container - disk clears automatically.

---

## Troubleshooting

### Disk Not Growing Fast Enough

**Increase traffic:**
- More Locust users (200+)
- Longer runtime (hours)

**Generate more logs:**
- Enable more error flags
- All flags that cause failures generate verbose logs

**Check log rotation isn't too aggressive:**
```bash
# Verify logging config was applied
docker inspect checkout | grep -A 5 LogConfig
```

### Docker System Running Out of Space

**Check available space:**
```bash
df -h /var/lib/docker
```

**Clean up:**
```bash
# Remove unused images/containers
docker system prune -a

# Remove volumes (careful!)
docker volume prune
```

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **Log accumulation** from high-traffic applications
2. ✅ **Disk growth patterns** from logging configuration
3. ✅ **Service degradation** under disk pressure
4. ✅ **Data store growth** (OpenSearch example)
5. ✅ **Correlation between** traffic volume and disk usage
6. ✅ **Resource management** in containerized environments
7. ✅ **Honeycomb monitoring** of service performance

---

## Comparison: This vs Code-Based Approach

| Aspect | No Code Changes (This) | Code Changes (Other Guide) |
|--------|------------------------|----------------------------|
| **Setup Time** | 5 minutes | 30+ minutes |
| **Code Changes** | None | Add Go code + feature flag |
| **Rebuild Required** | No | Yes |
| **Disk Growth Speed** | Slow (hours) | Fast (minutes) |
| **Predictability** | Variable | Precise |
| **Kubernetes Limits** | Works | Works better |
| **Observability** | Docker commands | Honeycomb + Docker |

---

## Recommendations

**For Quick Demo:**
- Use **Method 3 (Kubernetes)** if you have K8s cluster
- Set very low ephemeral-storage limit (100Mi)
- Generate moderate traffic
- Pod eviction happens in minutes

**For Docker Compose:**
- Use **Method 1 (Log Accumulation)**
- Modify logging config
- Run overnight with sustained load
- Better for long-term observation

**For Realistic Scenario:**
- Use **Method 2 (OpenSearch)**
- Flood with telemetry data
- Observe data store growth
- Most similar to production issues

---

## Summary

This guide shows **filesystem growth with ZERO code changes** using:
- ✅ Logging configuration changes
- ✅ Existing feature flags
- ✅ Load generation
- ✅ Observable in Honeycomb
- ✅ Quick to set up and test

**Key takeaway:** You can observe filesystem growth and disk pressure without writing any code - just by controlling logging behavior and generating sufficient load.
