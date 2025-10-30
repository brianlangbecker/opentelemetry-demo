# PostgreSQL IOPS Chaos Demo - Low Cache Scenario

**Goal:** Demonstrate visible IOPS pressure and performance degradation by reducing PostgreSQL cache below optimal levels.

---

## 🎯 **What This Shows**

**Normal Operation:**

- Database: ~280 MB
- Cache (shared_buffers): 128 MB (default)
- Cache Hit Ratio: **98-99%** (healthy) ✅

**Chaos/Degraded Operation:**

- Database: ~280 MB
- Cache (shared_buffers): **32 MB** (undersized)
- Cache Hit Ratio: **70-85%** (struggling) ❌

**Result:** Visible performance issues, increased disk I/O, slower queries

---

## 🚀 **Option 1: Configure via Helm Install (Recommended)**

### **Enable Low Cache at Install Time:**

Edit `infra/otel-demo-values.yaml`:

```yaml
components:
  postgresql:
    resources:
      limits:
        memory: 300Mi
      requests:
        memory: 300Mi
    envOverrides:
      - name: POSTGRES_SHARED_BUFFERS
        value: '32MB' # Undersized for chaos demo
```

Then install:

```bash
helm install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values infra/otel-demo-values.yaml \
  --create-namespace
```

**Result:** PostgreSQL starts with only 32 MB cache from the beginning.

---

## 🔧 **Option 2: Enable Chaos on Running System**

### **Method A: Helm Upgrade (Preserves Data with PVC)**

1. **Edit values file:**

   ```yaml
   postgresql:
     envOverrides:
       - name: POSTGRES_SHARED_BUFFERS
         value: '32MB'
   ```

2. **Upgrade:**

   ```bash
   helm upgrade otel-demo open-telemetry/opentelemetry-demo \
     -n otel-demo \
     --values infra/otel-demo-values.yaml \
     --reuse-values
   ```

3. **Restart PostgreSQL:**
   ```bash
   kubectl rollout restart deployment/postgresql -n otel-demo
   ```

### **Method B: Manual Configuration (Quick Test)**

```bash
# Set shared_buffers to 32MB
kubectl set env deployment/postgresql -n otel-demo \
  POSTGRES_SHARED_BUFFERS=32MB

# Restart to apply (automatic with set env)
kubectl rollout status deployment/postgresql -n otel-demo

# Verify
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -c "SHOW shared_buffers;"
```

**Expected Output:**

```
 shared_buffers
----------------
 32MB
```

---

## 📊 **Expected Results**

### **Before Chaos (128 MB cache):**

```sql
 datname | blks_read | blks_hit | cache_hit_ratio
---------+-----------+----------+-----------------
 otel    |    143106 | 11523711 |           98.77
```

**Interpretation:** Healthy - only 1.2% of reads hit disk

---

### **After Chaos (32 MB cache):**

```sql
 datname | blks_read | blks_hit | cache_hit_ratio
---------+-----------+----------+-----------------
 otel    |   2500000 | 14000000 |           84.85
```

**Interpretation:** Struggling - 15% of reads hit disk (12x increase)

---

## 📈 **Honeycomb Queries to Show Impact**

### **1. Cache Hit Ratio Degradation**

**Calculated Field:**

```
cache_hit_ratio = DIV(MUL($postgresql.blks_hit, 100), ADD($postgresql.blks_hit, $postgresql.blks_read))
```

**Query:**

```
DATASET: opentelemetry-demo
WHERE: postgresql.blks_hit EXISTS
VISUALIZE: AVG(cache_hit_ratio) AS "Cache Hit %"
GROUP BY: time(5m)
TIME RANGE: Last 2 hours
```

**Expected Graph:**

- **Before:** Flat line at ~98-99%
- **After chaos:** Drops to 70-85%
- **Clear degradation visible** 📉

---

### **2. Disk Read Rate Increase**

```
DATASET: opentelemetry-demo
WHERE: postgresql.blks_read EXISTS
VISUALIZE: SUM(RATE($postgresql.blks_read)) AS "Disk Reads/sec"
GROUP BY: time(1m)
TIME RANGE: Last 2 hours
```

**Expected Graph:**

- **Before:** ~0.5-1 blocks/sec
- **After chaos:** 5-10 blocks/sec (10x increase)
- **Spike visible at chaos enablement** 📈

---

### **3. Query Latency Impact**

```
DATASET: opentelemetry-demo
WHERE: name = "accountingService" AND db.statement EXISTS
VISUALIZE:
  P50(duration_ms) AS "p50",
  P95(duration_ms) AS "p95",
  P99(duration_ms) AS "p99"
GROUP BY: time(5m)
TIME RANGE: Last 2 hours
```

**Expected Impact:**

- **p50:** +20-50% increase
- **p95:** +100-200% increase
- **p99:** Potential timeouts

---

## 🎭 **Demo Narrative**

**Setup (5 minutes):**

1. Show healthy baseline metrics (98%+ cache hit ratio)
2. Explain: "Database is 280 MB, cache is 128 MB - appropriately sized"
3. Show Honeycomb dashboards with green metrics

**Introduce Chaos (1 minute):**

```bash
# Simulate misconfiguration or resource constraint
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=32MB
```

**Observe Impact (5-10 minutes):**

1. **Immediate:** Cache hit ratio drops to 70-85%
2. **Within 2 minutes:** Disk read rate increases 10x
3. **Within 5 minutes:** Query latency increases visible
4. Show Honeycomb alerts/dashboards turning red

**Remediate (1 minute):**

```bash
# Restore proper configuration
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=128MB
```

**Recovery (5 minutes):**

1. Cache hit ratio climbs back to 98%+
2. Disk reads return to baseline
3. Query latency normalizes

---

## 📋 **Cache Size Options**

| **shared_buffers**   | **DB Size** | **Ratio** | **Cache Hit %** | **Use Case**          |
| -------------------- | ----------- | --------- | --------------- | --------------------- |
| **128 MB (default)** | 280 MB      | 2.2x      | 98-99%          | ✅ Healthy baseline   |
| **64 MB**            | 280 MB      | 4.4x      | 90-95%          | ⚠️ Moderate pressure  |
| **32 MB**            | 280 MB      | 8.8x      | 70-85%          | ❌ **Chaos demo**     |
| **16 MB**            | 280 MB      | 17.5x     | 50-70%          | 🔥 Severe degradation |

**Recommendation for Chaos Demo:** **32 MB** - Shows clear impact without breaking the system completely.

---

## ⚠️ **Important Notes**

### **Memory Requirements:**

Even with low shared_buffers, PostgreSQL needs adequate **total memory**:

- **Minimum:** 300Mi (covers shared_buffers + work_mem + connections)
- **DO NOT reduce the 300Mi memory limit** - only reduce shared_buffers

**Wrong:**

```yaml
resources:
  limits:
    memory: 100Mi # ❌ Will crash
```

**Correct:**

```yaml
resources:
  limits:
    memory: 300Mi # ✅ Stable
envOverrides:
  - name: POSTGRES_SHARED_BUFFERS
    value: '32MB' # ✅ Low cache for demo
```

### **Data Persistence:**

- ✅ With PVC attached: Data survives configuration changes
- ❌ Without PVC: Must re-seed after restart

---

## 🔄 **Restore to Healthy State**

### **Via Helm:**

Edit `infra/otel-demo-values.yaml` - remove or comment out `envOverrides`:

```yaml
postgresql:
  resources:
    limits:
      memory: 300Mi
    requests:
      memory: 300Mi
  # envOverrides:  # Commented out = use default 128MB
  #   - name: POSTGRES_SHARED_BUFFERS
  #     value: "32MB"
```

Then upgrade:

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values infra/otel-demo-values.yaml
```

### **Via kubectl:**

```bash
# Remove custom env var (reverts to default 128MB)
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS-

# Or set explicitly
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=128MB
```

---

## 🎯 **Summary**

**This chaos demo shows:**

1. ✅ How to monitor PostgreSQL cache effectiveness
2. ✅ Impact of undersized cache on performance
3. ✅ How to detect IOPS issues before they become critical
4. ✅ Value of proper capacity planning and monitoring
5. ✅ Fast remediation with observability-driven decisions

**Perfect for demonstrating:**

- Observability best practices
- Capacity planning importance
- Performance troubleshooting
- Site Reliability Engineering (SRE) scenarios

---

## 📚 **Related Documentation**

- **Normal IOPS Demo:** `postgres-disk-iops-pressure.md`
- **Setup Guide:** `postgres-seed-for-iops.md`
- **Configuration Notes:** `infra/SETUP-NOTES.md`
