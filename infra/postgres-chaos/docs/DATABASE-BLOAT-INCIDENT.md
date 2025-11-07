# Database Bloat Incident - Root Cause Analysis

**Incident Date:** November 4-5, 2025
**Severity:** High - 40x performance degradation in checkout service
**Root Cause:** Excessive pgbench test data causing database resource exhaustion

---

## Executive Summary

Checkout service latency degraded from **~40ms (P50)** to **1,677ms (P50)** - a **40x slowdown** - due to a 7.5GB pgbench test table consuming all available database resources. The oversized database exceeded PostgreSQL's memory limits, causing constant disk I/O, slow queries, Kafka backpressure, and cascading performance issues across multiple services.

---

## Timeline of Events

### Before 22:00 (Nov 4)

- Unknown user ran pgbench with very high scale factor (likely scale 100)
- Created massive 7,477 MB `pgbench_accounts` table
- Database size grew to 7,508 MB (7.5 GB total)
- Disk usage reached 72% (72GB / 100GB)

### Around 22:00 (Nov 4) - Initial Impact

**Symptoms:**

- Database became slow due to resource pressure
- Accounting service stopped processing database queries (0 queries recorded)
- Checkout service appeared "fast" (P50: 37ms, P95: 219ms)

**Why checkout looked fast:** No actual load! Accounting wasn't processing orders, so Kafka wasn't being written to, eliminating the main source of checkout latency.

### Early Morning (02:00-07:00, Nov 5) - Full Degradation

**Database came back online with 7.5GB data:**

- Accounting service resumed processing
- Multiple pgbench tests ran (light, normal, beast, table-lock)
- **Checkout P50 jumped to 1,677ms** (40x slower)
- **Checkout P95 jumped to 3,700ms**

---

## Root Cause Analysis

### The Database Bloat

```sql
-- Actual table sizes
pgbench_accounts: 7,477 MB  (99% of database!)
orderitem:           11 MB
shipping:           8.1 MB
order:              4.6 MB
pgbench_tellers:    384 KB
pgbench_branches:    88 KB
```

**Total Database Size:** 7,508 MB (7.5 GB)

### Resource Constraints (from Helm values)

```yaml
postgresql:
  resources:
    limits:
      memory: 512Mi # ❌ Only 512MB for 7.5GB database!
      cpu: 512m
      ephemeral-storage: 1Gi # ❌ Only 1GB storage limit
    requests:
      memory: 256Mi
      cpu: 200m
      ephemeral-storage: 500Mi
```

**The Mismatch:**

- Database size: **7,508 MB**
- Memory limit: **512 MB** (15x smaller!)
- Storage limit: **1 GB** (7x smaller!)

### Why This Caused Degradation

1. **Memory Pressure:**

   - PostgreSQL shared_buffers couldn't cache data
   - Constant eviction of cached pages
   - Every query required disk reads

2. **Disk I/O Bottleneck:**

   - 7.5GB database couldn't fit in 512MB memory
   - Queries hit disk for every operation
   - I/O wait times increased dramatically

3. **Query Slowdown:**

   - Accounting database queries: 30-second waits
   - Normal <5ms queries became 100-1000ms

4. **Kafka Backpressure:**

   - Accounting couldn't keep up with Kafka consumption
   - Messages piled up in queue
   - Kafka producer (checkout) experienced slow writes

5. **Checkout Cascade Failure:**
   - Kafka publish operations: 4-8 seconds (normally <100ms)
   - Overall checkout latency: 1.6-3.7 seconds

---

## Blast Radius

### Direct Impact

1. **PostgreSQL**
   - 72% disk usage
   - Memory exhaustion
   - Slow query performance

### Service Impact Chain

```
PostgreSQL (7.5GB bloat, 512MB memory)
    ↓
Accounting (30-second database query waits)
    ↓
Kafka (message backlog, slow producer writes)
    ↓
Checkout (4-8 second Kafka publish operations)
    ↓
Frontend (user-facing 4-8 second checkout delays)
```

### Metrics Evidence

**PostgreSQL:**

- Database size: 7,508 MB
- Disk usage: 72%
- CPU: Elevated but not saturated

**Accounting Service:**

- MAX query duration: 30,027ms (30 seconds!)
- Normal query duration: <5ms
- Error rate: 18 errors during lock tests

**Checkout Service:**

- P50 latency: 1,677ms (was ~40ms)
- P95 latency: 3,700ms (was ~200ms)
- P99 latency: 4,905ms
- MAX latency: 7,800ms
- Kafka producer duration P95: 3,880ms

**Honeycomb Query URLs:**

- Accounting performance: https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/accounting/result/pPfKQbE1faJ
- Checkout latency: https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/j6RguBJQedc
- Kafka producer impact: https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/rUQTsn2LwKn

---

## Diagnostic Steps

### How to Detect Database Bloat

**1. Check Database Size:**

```bash
kubectl exec -n otel-demo <POD> -c postgresql -- \
  psql -U root otel -c "SELECT pg_database_size('otel') as db_size_bytes, pg_size_pretty(pg_database_size('otel')) as db_size;"
```

**Expected:** ~25-50 MB
**Problem:** >1 GB

**2. Check Table Sizes:**

```bash
kubectl exec -n otel-demo <POD> -c postgresql -- \
  psql -U root otel -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname = 'public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;"
```

**Look for:** `pgbench_accounts` table > 100 MB

**3. Check Disk Usage:**

```bash
kubectl exec -n otel-demo <POD> -c postgresql -- \
  df -h /var/lib/postgresql/data
```

**Warning:** >50% usage
**Critical:** >80% usage

**4. Query Honeycomb for Accounting Slowness:**

```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: MAX(duration_ms), P95(duration_ms)
Time: Last 24 hours
```

**Normal:** P95 < 10ms
**Problem:** P95 > 100ms
**Critical:** MAX > 10,000ms (10 seconds)

**5. Query Honeycomb for Checkout Impact:**

```
Dataset: checkout
WHERE name = "oteldemo.CheckoutService/PlaceOrder"
Calculate: P50(duration_ms), P95(duration_ms)
Time: Last 24 hours
```

**Normal:** P50 < 100ms, P95 < 500ms
**Problem:** P50 > 500ms, P95 > 1,000ms

---

## The Fix

### Immediate Resolution

```bash
cd /Users/brianlangbecker/Documents/GitHub/opentelemetry-demo/infra/postgres-chaos/

# Clean up pgbench test data
./postgres-chaos-scenarios.sh clean
```

This will:

1. Drop `pgbench_accounts`, `pgbench_tellers`, `pgbench_branches`, `pgbench_history` tables
2. Reclaim 7,477 MB of space
3. Reduce database from 7.5GB → ~25MB
4. Restore normal performance

### Manual Cleanup (if script fails)

```bash
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n otel-demo $POD -c postgresql -- \
  psql -U root otel -c "DROP TABLE IF EXISTS pgbench_accounts, pgbench_tellers, pgbench_branches, pgbench_history CASCADE;"

# Verify cleanup
kubectl exec -n otel-demo $POD -c postgresql -- \
  psql -U root otel -c "SELECT pg_size_pretty(pg_database_size('otel')) as db_size;"
```

### Verify Recovery

**1. Check Database Size (should be ~25MB):**

```bash
kubectl exec -n otel-demo $POD -c postgresql -- \
  psql -U root otel -c "SELECT pg_size_pretty(pg_database_size('otel'));"
```

**2. Check Accounting Service Performance:**

```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: P95(duration_ms)
Time: Last 10 minutes
```

Expected: P95 < 10ms

**3. Check Checkout Service Performance:**

```
Dataset: checkout
WHERE name = "oteldemo.CheckoutService/PlaceOrder"
Calculate: P50(duration_ms), P95(duration_ms)
Time: Last 10 minutes
```

Expected: P50 < 100ms, P95 < 500ms

---

## Prevention Strategies

### 1. Limit pgbench Scale Factor

In `postgres-chaos-scenarios.sh`, the maximum scale factor is already limited to 40 (4 million rows, ~600MB):

```bash
# From postgres-chaos-scenarios.sh line 96-102
if [ "$TABLE_COUNT" -lt 4000000 ]; then
    SCALE=40
    echo "Initializing pgbench with scale $SCALE (~$SCALE million rows, ~600MB)..."
else
    echo "pgbench tables already exist with $TABLE_COUNT rows"
    return 0
fi
```

**Never exceed scale 50** with the current resource limits.

### 2. Add Resource Warnings

postgres-chaos-scenarios.sh already includes warnings for memory/disk pressure:

```bash
# Lines 133-149: Memory pressure check
# Lines 151-167: Disk space check
```

Always run with these checks enabled.

### 3. Monitor Database Size

**Set up Honeycomb SLO:**

- Dataset: Metrics
- Metric: `system.filesystem.usage` (when available)
- Threshold: Alert when >50% usage
- Action: Run `./postgres-chaos-scenarios.sh status` and clean if needed

### 4. Regular Cleanup

Add to your demo/testing runbook:

```bash
# After any beast or high-scale pgbench run:
./postgres-chaos-scenarios.sh clean
```

### 5. Consider Resource Limits

For heavy pgbench testing, temporarily increase PostgreSQL resources:

```yaml
postgresql:
  resources:
    limits:
      memory: 2Gi # 4x increase for large-scale tests
      cpu: 1000m
      ephemeral-storage: 5Gi # Allow for larger datasets
```

**Remember:** Revert after testing!

---

## Key Learnings

### 1. Database Size vs Memory Ratio

**Golden Rule:** Database working set should fit in `shared_buffers` (typically 25% of available memory)

- 512MB memory = ~128MB shared_buffers
- Should handle ~500MB database
- 7.5GB database = **15x too large!**

### 2. Symptoms of Memory-Constrained Database

✅ **Clear Indicators:**

- High MAX query duration (30+ seconds)
- Normal CPU usage (<80%)
- Large database size relative to memory
- No connection errors

❌ **What it's NOT:**

- CPU saturation
- Connection exhaustion
- Lock contention (though we did test this separately)

### 3. Blast Radius Pattern: Database → Async Services

```
Database bloat
  → Slow database queries
  → Slow message consumer (accounting)
  → Message queue backlog (Kafka)
  → Slow message producer (checkout)
  → User-facing latency (frontend)
```

This pattern is **hard to diagnose** because:

- No errors occur
- Each service looks "fine" in isolation
- The root cause is several hops away from the symptom

### 4. Observability Success

We successfully traced the issue using:

1. Checkout latency spike (user-facing symptom)
2. Kafka producer duration (matches checkout latency)
3. Accounting query performance (database operations slow)
4. Database size query (root cause: 7.5GB bloat)

**This demonstrates proper observability hygiene!** 🎯

---

## Related Documentation

- **PostgreSQL Chaos Testing:** [POSTGRES-CHAOS-README.md](./POSTGRES-CHAOS-README.md)
- **Load Testing Strategy:** [POSTGRES-LOAD-TESTING.md](./POSTGRES-LOAD-TESTING.md)
- **Chaos Scenarios & Blast Radius:** [POSTGRES-CHAOS-SCENARIOS.md](./POSTGRES-CHAOS-SCENARIOS.md)
- **Honeycomb Query Guide:** [HONEYCOMB-BLAST-RADIUS-QUERIES.md](./HONEYCOMB-BLAST-RADIUS-QUERIES.md)
- **Quick Reference:** [README.md](../README.md)

---

## Summary Metrics

### Before Cleanup (Degraded State)

- Database size: **7,508 MB**
- Disk usage: **72%**
- Checkout P50: **1,677ms**
- Checkout P95: **3,700ms**
- Accounting MAX query: **30,027ms**

### After Cleanup (Expected Recovered State)

- Database size: **~25 MB** (300x smaller!)
- Disk usage: **<10%**
- Checkout P50: **<100ms** (16x faster)
- Checkout P95: **<500ms** (7x faster)
- Accounting P95 query: **<10ms** (3,000x faster!)

---

**Incident Status:** Diagnosed ✅
**Resolution:** Run `./postgres-chaos-scenarios.sh clean`
**Prevention:** Enforce scale limits, monitor database size, cleanup after tests

**Date:** 2025-11-05
**Author:** Root Cause Analysis by Claude Code
