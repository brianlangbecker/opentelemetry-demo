# Filesystem Growth / Disk Exhaustion - OpenSearch

Demonstrate filesystem/disk growth by flooding OpenSearch with telemetry data using feature flags and load generation. **Zero code changes required.**

## What It Does

**Target:** OpenSearch (stores all logs and traces)
**Method:** Flood with error logs using feature flags + sustained traffic
**Outcome:** Disk grows from ~900MB → 4-5GB in 2-3 hours
**Pattern:** Cumulative log accumulation

---

## Quick Start

**1. Enable error flags (FlagD UI: http://localhost:4000):**

| Flag | Setting | Effect |
|------|---------|--------|
| `kafkaQueueProblems` | `2000` | Massive Kafka logs per checkout |
| `cartFailure` | `on` | All cart ops fail with errors |
| `paymentFailure` | `100%` | All payments fail with stack traces |
| `adFailure` | `on` | Continuous error logs |

**2. Generate high traffic (Locust: http://localhost:8089):**
- Users: 50
- Runtime: 120-180m (2-3 hours)

**3. Expected growth (starting from ~760MB):**
```
760M → 1.0G (15min) → 1.4G (30min) → 2.0G (60min) → 3.3G (120min) → 4.8G (180min)
```

**Growth rate:** ~500MB-1GB per hour with error flags enabled

---

## Monitoring Disk Growth

### Check Current Size

```bash
kubectl exec -it opensearch-0 -n otel-demo -- du -sh /usr/share/opensearch/data
```

**Watch disk grow (updates every 10s):**
```bash
watch -n 10 "kubectl exec opensearch-0 -n otel-demo -- du -sh /usr/share/opensearch/data"
```

---

### Check Indices

**List indices with sizes:**
```bash
kubectl exec opensearch-0 -n otel-demo -- curl -s http://localhost:9200/_cat/indices?v
```

**Sorted by size (largest first):**
```bash
kubectl exec opensearch-0 -n otel-demo -- curl -s 'http://localhost:9200/_cat/indices?v&s=store.size:desc'
```

**Example output:**
```
health status index                    docs.count store.size
yellow open   otel-logs-2025-10-23         125847      1.2gb
yellow open   otel-logs-2025-10-22          98234    890.5mb
```

---

### Check Cluster Health

```bash
kubectl exec opensearch-0 -n otel-demo -- curl -s http://localhost:9200/_cluster/health?pretty
```

**Health statuses:**
- `"status": "green"` = Healthy
- `"status": "yellow"` = Warning (disk pressure starting)
- `"status": "red"` = Critical (disk full or service degraded)

---

## Honeycomb Monitoring

### OpenSearch Disk Usage

```
WHERE k8s.pod.name = "opensearch-0"
VISUALIZE MAX(k8s.pod.ephemeral-storage.used)
GROUP BY time(1m)
```

**Alternative - Filesystem usage:**
```
WHERE k8s.pod.name = "opensearch-0"
VISUALIZE MAX(k8s.filesystem.usage)
GROUP BY time(30s)
```

**Expected:** Steady upward trend, ~500MB-1GB per hour

---

### Log Volume (Driving Disk Growth)

```
WHERE service.name EXISTS
VISUALIZE COUNT
GROUP BY time(1m)
```

**With error flags enabled:** 10-100x increase in log volume

---

### Checkout Activity (Primary Driver)

```
WHERE service.name = "checkout" AND name = "PlaceOrder"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Note:** Each checkout with `kafkaQueueProblems: 2000` generates ~250KB of logs

---

### Error Rate

```
WHERE service.name EXISTS
VISUALIZE COUNT
GROUP BY service.name, otel.status_code
```

**Note:** Errors generate much more verbose logs than success

---

### OpenSearch Performance Degradation

```
WHERE service.name = "opensearch" OR k8s.pod.name = "opensearch-0"
VISUALIZE P95(duration_ms)
GROUP BY time(1m)
```

**Pattern:** As disk fills, OpenSearch queries slow down

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

**Note:** With 50 users, run 2-4 hours to see significant disk growth.

---

## Alerts

### Alert 1: High Disk Usage

**Query:**
```
WHERE k8s.pod.name = "opensearch-0"
VISUALIZE MAX(k8s.pod.ephemeral-storage.used)
GROUP BY time(5m)
```

**Trigger:**
- **Threshold:** MAX(k8s.pod.ephemeral-storage.used) > 4GB
- **Duration:** For at least 5 minutes
- **Severity:** WARNING

**Notification:**
```
⚠️ OpenSearch Disk Usage High

Pod: opensearch-0
Disk Usage: {{MAX(k8s.pod.ephemeral-storage.used)}} bytes

Action: Check log retention policies or increase storage
```

---

### Alert 2: Cluster Health Degraded

**Manual check:**
```bash
kubectl exec opensearch-0 -n otel-demo -- curl -s http://localhost:9200/_cluster/health | jq -r .status
```

**Expected:** "green" (healthy)
**Warning:** "yellow" (disk pressure)
**Critical:** "red" (disk full)

---

## Troubleshooting

### Disk Not Growing Fast Enough

**Increase traffic:**
- More Locust users (200+)
- Longer runtime

**Generate more logs:**
- Enable more error flags
- All failure flags generate verbose logs

---

### Cluster Running Out of Space

**Check node space:**
```bash
kubectl get nodes
kubectl describe node <node-name> | grep -A 10 "Allocated resources"
```

---

## Cleanup

**Restart pod (clears disk automatically):**
```bash
kubectl delete pod opensearch-0 -n otel-demo
```

**Disable flags (FlagD UI):**
- Set all error flags back to `off`

**Stop load test:**
- Stop Locust (http://localhost:8089)

---

## Key Points

1. **Zero code changes** - Uses existing feature flags
2. **Log accumulation** - High error rate = high log volume
3. **Disk growth correlation** - Traffic volume drives disk usage
4. **Service degradation** - Performance slows as disk fills
5. **Easy reset** - Restart pod to clear disk

---

## Production Scenarios Simulated

- Log retention issues
- High error rates causing disk pressure
- Data store growth without cleanup
- Service degradation under disk pressure
- Resource management in containerized environments

---

**Growth Rate:** ~500MB-1GB/hour | **Runtime:** 2-4 hours | **Zero Code Changes:** ✅
