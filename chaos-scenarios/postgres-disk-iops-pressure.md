# Postgres Disk & IOPS Pressure - Database Storage Exhaustion

## Quick Setup

**Goal:** Demonstrate database disk growth and I/O pressure observable in Honeycomb using native PostgreSQL metrics.

### Option 1: ⭐ Recommended - High Traffic, No Flag (2-4 hours)

**Best approach for clean, reliable IOPS demonstration:**

1. **CRITICAL: Increase accounting memory first:**
   ```bash
   kubectl set resources deployment accounting -n otel-demo --limits=memory=256Mi --requests=memory=128Mi
   ```
2. **Disable flag:** FlagD UI (http://localhost:4000) → `kafkaQueueProblems` = `off` (defaultVariant)
3. **Start load:** Locust (http://localhost:8089) → Users: `200`, Spawn rate: `20`, Runtime: `240m`
4. **Monitor in Honeycomb:** Cache hit ratio query (see below)
5. **Runtime:** 2-4 hours for observable IOPS pressure

**Why this works:**

- ✅ 100% success rate (no duplicate order errors)
- ✅ Predictable growth rate (~110MB/hour)
- ✅ Safe for all services (no OOM risk)
- ✅ Realistic production-like traffic patterns
- ✅ **Observable IOPS in 2 hours, nasty IOPS in 4 hours**

### Option 2: 🚀 Fast IOPS (1-2 hours) - Reduce PostgreSQL Cache

**For time-constrained demos - force IOPS pressure faster:**

1. **Reduce PostgreSQL memory:**
   ```bash
   kubectl set resources deployment postgresql -n otel-demo --limits=memory=50Mi
   ```
2. **Start load:** Locust → Users: `200`, Runtime: `120m`
3. **Result:** Nasty IOPS in **~2 hours** instead of 4 (smaller cache fills faster)

**Key Metrics in Honeycomb (opentelemetry-demo dataset):**

- `postgresql.blks_hit` / `postgresql.blks_read` = Cache hit ratio (watch it degrade)
- `postgresql.tup_inserted` = Write volume
- Accounting service latency (correlates with I/O pressure)

**Important:** PostgreSQL metrics are in the **opentelemetry-demo** dataset (or custom Metrics dataset if configured) - use queries with `RATE()` and `INCREASE()` functions (see below)

**⚠️ Critical Bottleneck:** Checkout service has only **20Mi memory** - **200 users is the tested maximum safe limit**. Higher values risk OOM crashes. Monitor checkout memory closely!

### Option 3: ⚡ Instant IOPS (Optional Pre-Seeding)

**Skip the wait - start with a pre-loaded database showing immediate IOPS pressure:**

See **[postgres-seed-for-iops.md](postgres-seed-for-iops.md)** for complete instructions to:

- Pre-seed 150,000 orders (~200+ MB) into PostgreSQL
- Configure persistent storage (data survives restarts)
- Set PostgreSQL memory to 300Mi (required for stability)
- **Result:** Immediate cache pressure from the start!

**Timeline:** 10 minutes setup vs. 2-4 hours wait ⏱️

### Option 4: 🎭 Chaos Demo - Visible IOPS Degradation (Immediate Impact)

**Show dramatic performance impact by undersizing the cache:**

**What this shows:**

- Normal: 128 MB cache, 98-99% cache hit ratio ✅
- Chaos: 32 MB cache, 70-85% cache hit ratio ❌
- Result: 10x increase in disk reads, slower queries

**Quick Setup (1 minute):**

```bash
# Reduce shared_buffers from 128MB → 32MB
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=32MB

# Restart to apply
kubectl rollout restart deployment/postgresql -n otel-demo
```

**Expected Results in Honeycomb:**

```
DATASET: opentelemetry-demo
WHERE postgresql.blks_hit EXISTS
VISUALIZE
  SUM(INCREASE(postgresql.blks_hit)) /
  (SUM(INCREASE(postgresql.blks_hit)) + SUM(INCREASE(postgresql.blks_read))) * 100
GROUP BY time(5m)
```

- **Before:** 98-99% cache hit ratio
- **After:** 70-85% cache hit ratio (visible degradation)

**Timeline:** Immediate impact - perfect for live demos! 🎬

**Restore:**

```bash
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=128MB
kubectl rollout restart deployment/postgresql -n otel-demo
```

---

## Honeycomb Queries - Start Here

> **Dataset Configuration:** PostgreSQL metrics flow to your configured dataset (typically `opentelemetry-demo` or a custom `Metrics` dataset).
>
> **Important:** These queries use `RATE()` and `INCREASE()` functions which work with cumulative counters. Make sure the PostgreSQL receiver is enabled in your collector config (see Prerequisites below).
>
> **About "Jagged" Charts:** These queries will show jagged/spiky patterns - **this is normal and correct!** It reflects real database workload variation. Look for **trends** (upward/downward over time), not individual spikes.

### Primary Query: PostgreSQL Cache Hit Ratio

```
DATASET: opentelemetry-demo
WHERE postgresql.blks_hit EXISTS OR postgresql.blks_read EXISTS
VISUALIZE
  SUM(INCREASE(postgresql.blks_hit)) /
  (SUM(INCREASE(postgresql.blks_hit)) + SUM(INCREASE(postgresql.blks_read))) * 100
GROUP BY time(5m)
TIME RANGE: Last 4 hours
```

**Expected with 200 users:**

- Start: 99.5% (everything cached)
- 2 hours: 95-97% (moderate IOPS)
- 4 hours: 85-88% (nasty IOPS!) 🎯

### PostgreSQL Disk Read Activity

```
DATASET: opentelemetry-demo
WHERE postgresql.blks_read EXISTS
VISUALIZE SUM(INCREASE(postgresql.blks_read))
GROUP BY time(5m)
TIME RANGE: Last 4 hours
```

**Watch:** Upward trend = increasing disk I/O pressure (jagged but climbing)

### PostgreSQL Write Rate (Real-Time)

```
DATASET: opentelemetry-demo
WHERE postgresql.tup_inserted EXISTS
VISUALIZE SUM(RATE(postgresql.tup_inserted))
GROUP BY time(1m)
TIME RANGE: Last 4 hours
```

**Shows:** Inserts per second

- Expected with 200 users: ~150-200 inserts/sec

### PostgreSQL Write Volume (Smoother)

```
DATASET: opentelemetry-demo
WHERE postgresql.tup_inserted EXISTS
VISUALIZE SUM(INCREASE(postgresql.tup_inserted))
GROUP BY time(10m)
TIME RANGE: Last 4 hours
```

**Shows:** Total inserts per 10-minute window (less jagged, shows trend)

### Accounting Service Latency

```
WHERE service.name = accounting
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**Expected:** P95 increases from 50ms → 250ms+ as disk pressure builds

### Disk vs Cache Read Rate

```
DATASET: opentelemetry-demo
WHERE postgresql.blks_read EXISTS OR postgresql.blks_hit EXISTS
VISUALIZE
  SUM(RATE(postgresql.blks_read)) AS "Disk Reads/sec",
  SUM(RATE(postgresql.blks_hit)) AS "Cache Hits/sec"
GROUP BY time(1m)
TIME RANGE: Last 4 hours
```

**Watch:** Disk reads/sec increasing while cache hit rate varies (both jagged)

---

> ⚠️ **CRITICAL: Memory Constraints**
>
> **The Real Bottleneck: Checkout Service (20Mi)**
>
> The **checkout service has only 20Mi memory** - this is the primary constraint, NOT the accounting service (120Mi).
>
> **Safe User Limits:**
>
> - **Checkout service memory limit**: **20Mi** ⚠️ (very low!)
> - **Tested maximum users**: **200** (sweet spot - reliable and safe) ✅
> - **DO NOT exceed 200 users** without increasing checkout memory
> - **Accounting service**: **256Mi REQUIRED** (not 120Mi - will OOM!)
> - **PostgreSQL**: 100Mi (can reduce to 50Mi for faster IOPS)
>
> **Why checkout is the bottleneck:**
>
> - Each user spawns goroutines for Kafka messaging
> - With `kafkaQueueProblems` flag, this multiplies exponentially
> - **20Mi memory** limits concurrent user capacity
> - Goal is **disk growth**, not memory exhaustion
>
> **Recommended Approach:**
>
> - Use **200 users WITHOUT kafkaQueueProblems flag** for clean, reliable IOPS demonstration
> - This avoids duplicate order errors and OOM issues
> - Provides predictable ~110MB/hour database growth

## Overview

This guide demonstrates how to observe **database disk growth and I/O pressure** using the OpenTelemetry Demo's Postgres database and accounting service, with telemetry sent to Honeycomb for analysis.

**✨ Key Feature: Direct PostgreSQL Metrics in Honeycomb**

The OpenTelemetry Collector includes a **PostgreSQL receiver** that scrapes database metrics (cache hit ratio, tuple operations, disk I/O) and exports them to Honeycomb alongside your application traces and logs. This provides complete database observability without additional tools.

### Use Case Summary

- **Target Service:** `accounting` (C# microservice) + `postgresql` (Postgres database)
- **Database:** PostgreSQL (stores order transactions)
- **Trigger Mechanism:** High user load (200 users) - NO feature flags needed
- **Observable Outcome:** Database growth → I/O pressure → Query latency degradation → Cache thrashing
- **Pattern:** Transactional write pressure (OLTP workload)
- **Monitoring:** Honeycomb UI with **native PostgreSQL metrics** (blks_hit, blks_read, tup_inserted, deadlocks) + application traces + K8s metrics
- **⚠️ Tested Settings:** **200 users (maximum safe limit)**, no flags, 2-4 hours runtime

---

## Related Scenarios Using `kafkaQueueProblems` Flag

The same feature flag creates different failure modes depending on the target:

| Scenario                                                                   | Target                         | Approach              | Users   | Observable Outcome                      |
| -------------------------------------------------------------------------- | ------------------------------ | --------------------- | ------- | --------------------------------------- |
| **[Memory Spike](chaos-scenarios/memory-tracking-spike-crash.md)**         | Checkout service (Go)          | Flag: 2000            | 50      | OOM crash in 60-90s                     |
| **[Gradual Memory Leak](chaos-scenarios/memory-leak-gradual-checkout.md)** | Checkout service (Go)          | Flag: 200-300         | 25      | Gradual OOM in 10-20m                   |
| **[Postgres Disk/IOPS](postgres-disk-iops-pressure.md)**                   | Postgres database + Accounting | **High traffic load** | **200** | Disk growth + I/O pressure (this guide) |

**Key Difference:** Memory scenarios crash the checkout service. This scenario fills the Postgres database with transactional data.

**⚠️ Critical Notes:**

- **Checkout service (20Mi memory)** is the primary bottleneck for user capacity
- **200 users is the tested maximum** - provides optimal IOPS demonstration
- **Accounting service requires 256Mi** - default 120Mi will OOM after 10-25 minutes
- **MUST increase accounting memory before starting** (see command above)
- If accounting crashes, database writes stop and the IOPS demo fails
- DO NOT use feature flags - they cause duplicate order errors and worsen memory issues

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- Kubernetes cluster with kubectl access
- Access to Honeycomb UI
- FlagD UI accessible

**⚠️ Before starting, verify Postgres is running and receiving data:**

- See **[verify-postgres.md](../infra/verify-postgres.md)** for comprehensive verification queries
- Quick check: `kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"`
- Expected: Should return a row count (may be 0 initially, but proves database is accessible)

### ⚠️ CRITICAL: Enable PostgreSQL Receiver in Metrics Pipeline

**By default, the PostgreSQL receiver is configured but NOT included in the metrics pipeline!** You must add it:

**In your `infra/otel-demo-values.yaml` (or `otel-demo-values-aws.yaml`):**

```yaml
opentelemetry-collector:
  config:
    service:
      pipelines:
        metrics:
          receivers:
            - spanmetrics
            - kubeletstats
            - k8s_cluster
            - postgresql # ← ADD THIS LINE!
          exporters:
            - otlp/honeycomb
            - debug
```

**Then upgrade your Helm release:**

```bash
cd infra
helm upgrade otel-demo open-telemetry/opentelemetry-demo -n otel-demo --values otel-demo-values.yaml
```

### Verify PostgreSQL Metrics in Honeycomb

**Confirm the OpenTelemetry Collector is scraping PostgreSQL metrics:**

1. **Open Honeycomb UI:** https://ui.honeycomb.io
2. **Navigate to your dataset:** `opentelemetry-demo` (or your configured dataset)
3. **Run this query:**
   ```
   DATASET: opentelemetry-demo
   WHERE postgresql.blks_hit EXISTS OR postgresql.blks_read EXISTS
   VISUALIZE COUNT
   TIME RANGE: Last 1 hour
   ```

**Expected result:**

- You should see data points indicating PostgreSQL metrics are flowing
- If no data appears, check:
  - **PostgreSQL receiver is in the metrics pipeline** (see above)
  - OTel Collector logs: `kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector`
  - PostgreSQL pod is running: `kubectl get pod -n otel-demo | grep postgresql`

**Available PostgreSQL metrics to verify:**

```
DATASET: opentelemetry-demo
WHERE postgresql.tup_inserted EXISTS
OR postgresql.tup_updated EXISTS
OR postgresql.tup_deleted EXISTS
OR postgresql.blks_hit EXISTS
OR postgresql.blks_read EXISTS
OR postgresql.deadlocks EXISTS
VISUALIZE COUNT
TIME RANGE: Last 1 hour
```

**If metrics don't appear after 2-3 minutes:**

- Verify `postgresql` is in the `receivers` list: `kubectl get configmap otel-collector -n otel-demo -o yaml | grep -A 10 "metrics:"`
- Check collector logs for errors: `kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector --tail=100`

Once you see PostgreSQL metrics in Honeycomb, you're ready to proceed! The PostgreSQL receiver scrapes these every 10 seconds and exports them as cumulative monotonic counters, which work with `RATE()` and `INCREASE()` functions.

---

## How It Works

When `kafkaQueueProblems` flag is enabled:

1. **Checkout service** creates hundreds of Kafka messages per order
2. **Accounting service** consumes ALL messages from Kafka topic
3. **For each message**, accounting service writes to Postgres:
   - 1 Order record (`orders` table)
   - N OrderItem records (`cart_items` table) - one per product
   - 1 Shipping record (`shipping` table)
4. **Database tables grow** with each processed message
5. **I/O pressure builds** from sustained writes
6. **Query latency increases** as tables grow and I/O saturates

**Production Analog:** Simulates RDS/Aurora database under high transaction volume with disk space or IOPS constraints.

---

## Execution Steps

### Step 1: Check Baseline Postgres Status

```bash
# Get postgres pod name
kubectl get pod -n otel-demo | grep postgresql

# Check database size
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT pg_size_pretty(pg_database_size('otel'));"

# Check table sizes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"

# Check disk usage
kubectl exec -n otel-demo postgresql-0 -- du -sh /var/lib/postgresql/data
```

**Expected baseline:**

```
Database size: ~50MB
orders table: ~8KB
cart_items table: ~8KB
shipping table: ~8KB
```

### Step 2: Enable Feature Flag

1. **Access FlagD UI:**

   ```
   http://localhost:4000
   ```

2. **Configure the flag:**
   - Find `kafkaQueueProblems` in the flag list
   - Click to expand/edit it
   - Set the **"on" variant value** to `100` (optimal for 120Mi accounting service)
   - Set **default variant** to `on`
   - Save changes

**What this does:** Each checkout creates 100 Kafka messages, all consumed by accounting service and written to Postgres.

**⚠️ Important - Accounting Service has 120Mi Memory:**

- **Use `100`** - this is optimal for 120Mi accounting service memory
- This allows 3-4 hours of observable disk growth without OOM
- **DO NOT use 200+ with this memory limit** - accounting service will OOM
- Higher flag values cause message buffering which exhausts the 120Mi limit

### Step 3: Generate Sustained Load

1. **Access Locust Load Generator:**

   ```
   http://localhost:8089
   ```

2. **Configure load test:**
   - Click **"Edit"** button
   - **Number of users:** `10-15` (optimal for 120Mi accounting service)
   - **Ramp up:** `5` (users per second)
   - **Runtime:** `180m` to `240m` (3-4 hours for observable growth)
   - Click **"Start"**

**Why conservative load:**

- Accounting service has only **120Mi memory** - this is the bottleneck
- Database growth is cumulative (data persists)
- Lower user count + lower flag value = safe, gradual disk growth
- Longer runtime compensates for slower growth rate

**⚠️ Scaling Guide for 120Mi Accounting Service:**

- **Optimal (recommended):** kafkaQueueProblems: **100**, users: **10-15** ✅
- **Maximum safe:** kafkaQueueProblems: **150**, users: **10** ⚠️
- **Will OOM:** kafkaQueueProblems: 200+, users: 15+ ❌

**Why not higher?**

- Accounting service buffers Kafka messages in memory before writing to Postgres
- Each message creates ~3 database write operations
- With 120Mi memory, the service can only handle ~50-100 messages in flight
- Higher values cause memory exhaustion before disk patterns emerge

### Step 4: Monitor Database Growth in Real-Time

**Watch database size (updates every 60 seconds):**

```bash
watch -n 60 'kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT pg_size_pretty(pg_database_size(\"otel\"));"'
```

**Expected growth pattern (with kafkaQueueProblems: 100, users: 12 - OPTIMAL FOR 120Mi):**

```
TIME    DATABASE SIZE    ACCOUNTING MEMORY    POSTGRES MEMORY    STATUS
0m      50MB            45Mi                 40Mi               Baseline
60m     200MB           70Mi                 60Mi               Growing steadily
120m    400MB           85Mi                 80Mi               Moderate growth
180m    700MB           95Mi                 100Mi              I/O pressure building
240m    1GB             105Mi                120Mi              Observable disk pressure
300m    1.3GB           110Mi                130Mi              Clear IOPS patterns
```

**⚠️ If you see accounting service OOM (killed/restarting):**

- Your settings are too aggressive for 120Mi memory
- **Immediately reduce `kafkaQueueProblems`**: 100 → 50
- **Reduce user count**: 12 → 8
- The bottleneck is **accounting service memory**, not Postgres
- Goal is **disk growth**, not memory exhaustion

**Monitor table growth:**

```bash
watch -n 60 'kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)), n_live_tup FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"'
```

**Expected output:**

```
  relname   | pg_size_pretty | n_live_tup
------------+----------------+------------
 cart_items | 1200 MB        |  2500000   (most records - one per product per message)
 orders     |  800 MB        |  1000000   (one per message)
 shipping   |  600 MB        |  1000000   (one per message)
```

**Check I/O statistics:**

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT datname, blks_read, blks_hit, blk_read_time, blk_write_time FROM pg_stat_database WHERE datname='otel';"
```

**What to look for:**

- `blks_read` - Disk reads (increases as cache misses grow)
- `blks_hit` - Cache hits (ratio should stay high)
- `blk_read_time` - Time spent reading from disk (increases under I/O pressure)
- `blk_write_time` - Time spent writing to disk (increases with sustained writes)

**Monitor disk I/O wait:**

```bash
kubectl top pod -n otel-demo | grep postgresql
```

**⚠️ CRITICAL: Watch for OOM During Test**

**For Standard Run (kafkaQueueProblems: 100):**

```bash
# Watch both accounting and postgres memory
watch -n 10 'kubectl top pod -n otel-demo | grep -E "accounting|postgresql"'
```

**For 30-Minute Accelerated Run (kafkaQueueProblems: 175) - CRITICAL MONITORING:**

```bash
# Watch accounting memory CLOSELY - update every 10 seconds
watch -n 10 'kubectl top pod -n otel-demo | grep accounting'
```

**Expected memory progression for 30-minute run:**

```
TIME    ACCOUNTING MEMORY    ACTION
0m      45Mi                 ✅ Safe - continue
5m      65Mi                 ✅ Safe - continue
10m     80Mi                 ✅ Safe - continue
15m     90Mi                 ⚠️ Watch closely
20m     100Mi                ⚠️ Approaching limit
25m     105Mi                🟡 Close to target
30m     108Mi                🛑 STOP NOW - target reached
35m+    110-115Mi            🚨 DANGER - reduce load immediately
```

**If accounting memory exceeds 105Mi before 30 minutes:**

1. **Reduce flag immediately:** FlagD UI → kafkaQueueProblems: 175 → 150
2. Continue monitoring
3. Goal is to reach 30 minutes without OOM

**Safe operating ranges for Accounting Service (120Mi limit):**

- **45-80Mi**: ✅ Safe - normal operation
- **80-100Mi**: ⚠️ Moderate - monitor closely
- **100-115Mi**: 🟡 Warning - approaching limit
- **115Mi+**: 🚨 **DANGER** - reduce load immediately or OOM imminent

**Safe operating ranges for Postgres:**

- **40-100Mi**: ✅ Safe
- **100-150Mi**: ⚠️ Moderate
- **150Mi+**: 🟡 Monitor

**If accounting service memory exceeds 100Mi:**

1. **Immediately stop Locust load test** (http://localhost:8089 → Stop)
2. **Reduce kafkaQueueProblems flag**: 100 → 50
3. **Reduce users**: 12 → 8
4. **Restart load test** with reduced settings

**Critical:** The **accounting service** (120Mi) will OOM before Postgres does - it's your bottleneck!

**Check for OOM events:**

```bash
kubectl get events -n otel-demo --sort-by='.lastTimestamp' | grep -i oom
kubectl describe pod -n otel-demo postgresql-0 | grep -A 10 "Last State"
```

---

## Honeycomb Dashboard Configuration

Create a board named **"Postgres Disk & I/O Pressure Analysis"** with these panels:

> **Note:** All PostgreSQL metrics queries use the **Metrics** dataset. Charts will appear jagged - this is normal and shows real workload variation.

### Panel 1: PostgreSQL Cache Hit Ratio (PRIMARY METRIC)

```
DATASET: Metrics
WHERE postgresql.blks_hit EXISTS OR postgresql.blks_read EXISTS
VISUALIZE
  SUM(INCREASE(postgresql.blks_hit)) /
  (SUM(INCREASE(postgresql.blks_hit)) + SUM(INCREASE(postgresql.blks_read))) * 100
GROUP BY time(5m)
```

**Critical metric - watch for downward trend indicating I/O pressure**

### Panel 2: PostgreSQL Disk Read Activity

```
DATASET: Metrics
WHERE postgresql.blks_read EXISTS
VISUALIZE SUM(INCREASE(postgresql.blks_read))
GROUP BY time(5m)
```

**Upward trend = increasing disk I/O**

### Panel 3: PostgreSQL Write Volume

```
DATASET: Metrics
WHERE postgresql.tup_inserted EXISTS
VISUALIZE SUM(INCREASE(postgresql.tup_inserted))
GROUP BY time(10m)
```

**Shows total inserts per 10-minute window**

### Panel 4: PostgreSQL Disk vs Cache Read Rate

```
DATASET: Metrics
WHERE postgresql.blks_read EXISTS OR postgresql.blks_hit EXISTS
VISUALIZE
  SUM(RATE(postgresql.blks_read)) AS "Disk Reads/sec",
  SUM(RATE(postgresql.blks_hit)) AS "Cache Hits/sec"
GROUP BY time(1m)
```

**Real-time I/O activity (will be jagged)**

### Panel 5: PostgreSQL All Write Operations

```
DATASET: Metrics
WHERE postgresql.tup_inserted EXISTS OR postgresql.tup_updated EXISTS OR postgresql.tup_deleted EXISTS
VISUALIZE
  SUM(INCREASE(postgresql.tup_inserted)) AS "Inserts",
  SUM(INCREASE(postgresql.tup_updated)) AS "Updates",
  SUM(INCREASE(postgresql.tup_deleted)) AS "Deletes"
GROUP BY time(10m)
```

**Complete write activity view**

### Panel 6: Accounting Service Latency

```
WHERE service.name = accounting
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

**Application-level view of database pressure**

### Panel 7: Database Write Latency (Application View)

```
WHERE service.name = accounting AND db.operation = INSERT
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

**INSERT operation latency from app perspective**

### Panel 8: Order Processing Volume

```
WHERE service.name = accounting
VISUALIZE COUNT
GROUP BY time(1m)
```

**Correlate with PostgreSQL metrics**

### Panel 9: PostgreSQL Deadlocks

```
DATASET: Metrics
WHERE postgresql.deadlocks EXISTS
VISUALIZE MAX(postgresql.deadlocks)
GROUP BY time(1m)
```

**Lock contention indicator (use MAX for cumulative counter)**

### Panel 10: Postgres CPU & Memory (if available)

```
WHERE k8s.pod.name STARTS_WITH postgresql
VISUALIZE MAX(k8s.pod.cpu_utilization), MAX(k8s.pod.memory.working_set)
GROUP BY time(1m)
```

**Infrastructure metrics for correlation**

---

## Advanced Postgres Monitoring

### Check Table Bloat

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"
```

### Check Active Connections

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT count(*), state FROM pg_stat_activity WHERE datname='otel' GROUP BY state;"
```

### Check Lock Contention

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT mode, count(*) FROM pg_locks WHERE database = (SELECT oid FROM pg_database WHERE datname='otel') GROUP BY mode;"
```

### Check Cache Hit Ratio

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "
SELECT
  datname,
  round(100.0 * blks_hit / (blks_hit + blks_read), 2) AS cache_hit_ratio
FROM pg_stat_database
WHERE datname='otel';"
```

**Expected:**

- Baseline: >99% cache hit ratio
- Under pressure: <95% (more disk I/O)

### Check Row Count Growth

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "
SELECT
  relname AS table_name,
  n_live_tup AS row_count,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;"
```

---

## Expected Timeline

### ⭐ RECOMMENDED: 200 Users, No Flag (PostgreSQL 100Mi memory)

**Clean, reliable approach with predictable growth:**

| Time | Database Size | Row Count (orders) | Cache Hit % | Query Latency | Checkout Memory | Postgres Memory | IOPS Level      |
| ---- | ------------- | ------------------ | ----------- | ------------- | --------------- | --------------- | --------------- |
| 0m   | 10MB          | 0                  | 99.8%       | P95: 20ms     | 12Mi            | 40Mi            | None            |
| 60m  | 120MB         | 30k                | 98-99%      | P95: 40ms     | 16Mi            | 60Mi            | Light           |
| 120m | 230MB         | 60k                | 95-97%      | P95: 80ms     | 17Mi            | 75Mi            | **Moderate** 🟡 |
| 180m | 340MB         | 90k                | 90-93%      | P95: 150ms    | 18Mi            | 85Mi            | **Heavy** 🟠    |
| 240m | 450MB         | 120k               | 85-88%      | P95: 250ms    | 19Mi            | 95Mi            | **Nasty** 🔴    |

**Key Milestones:**

- **2 hours**: Observable IOPS (cache hit 95-97%)
- **3 hours**: Heavy IOPS (cache hit 90-93%)
- **4 hours**: **Nasty IOPS** (cache hit 85-88%) 🎯

**Why this is optimal:**

- ✅ **100% success rate** (no duplicate order errors from kafkaQueueProblems)
- ✅ **Checkout service safe** (stays under 20Mi limit)
- ✅ **Predictable growth** (~110MB/hour)
- ✅ **Production-realistic** traffic patterns
- ✅ **No OOM risk**

**Growth rate:** ~110MB per hour, ~30,000 orders per hour

**⚠️ 200 users is the tested upper limit:**

- Tested and verified as safe maximum capacity
- Checkout service (20Mi) operates safely at 16-19Mi
- Accounting service (120Mi) operates safely at 50-70Mi
- Provides optimal balance of speed and stability
- DO NOT exceed without increasing checkout memory limits

**🔴 CRITICAL: Accounting service must stay running for this demo to work!**

- Accounting writes ALL data to PostgreSQL
- If accounting crashes, database writes stop = IOPS demo stops
- With 200 users (no flag), accounting is perfectly safe (50-70Mi used of 120Mi limit)

---

### 🚀 FAST IOPS: 200 Users, Reduced PostgreSQL Memory (50Mi)

**Force IOPS pressure faster by reducing cache:**

| Time | Database Size | Row Count (orders) | Cache Hit % | Query Latency | IOPS Level   | Status               |
| ---- | ------------- | ------------------ | ----------- | ------------- | ------------ | -------------------- |
| 0m   | 10MB          | 0                  | 99.8%       | P95: 20ms     | None         | Baseline             |
| 60m  | 120MB         | 30k                | 93-95%      | P95: 100ms    | **Moderate** | 🟡 Cache pressure    |
| 120m | 230MB         | 60k                | 85-88%      | P95: 300ms    | **Nasty**    | 🔴 **Goal reached!** |

**Key change:**

```bash
kubectl set resources deployment postgresql -n otel-demo --limits=memory=50Mi
```

**Why this works:**

- Halves PostgreSQL cache (50Mi instead of 100Mi)
- Database exceeds cache much sooner (~150MB vs ~300MB)
- **Nasty IOPS in 2 hours** instead of 4
- Perfect for time-constrained demos

**Trade-off:** More aggressive cache thrashing, but safe for all services

---

### ⚠️ Legacy Approach: kafkaQueueProblems Flag (NOT Recommended)

**The `kafkaQueueProblems` flag has issues:**

- ❌ Causes duplicate order errors (~40-60% failure rate)
- ❌ Unpredictable growth due to failed writes
- ❌ Checkout service OOM risk (20Mi memory is very tight)
- ❌ Accounting service can also fail with high values

**If you must use the flag:**

- Maximum safe value: `kafkaQueueProblems: 20-35`
- Users: 10-15 max
- Expected failures: 30-40%
- Monitor checkout memory closely

**Why the new approach is better:**

- 200 users WITHOUT flag = clean, predictable load
- Faster IOPS pressure than flag-based approach
- No errors, no OOM risk, easier to demonstrate

---

## Alert Configuration

### Alert 1: Database Size Growth

```
TRIGGER: Database size > 2GB
WHERE: service.name = postgresql
FREQUENCY: Every 5 minutes
ACTION: Warning - database growing rapidly
```

### Alert 2: High Write Latency

```
TRIGGER: P95(duration_ms) > 300
WHERE: service.name = accounting AND db.operation = INSERT
FREQUENCY: Every 1 minute
ACTION: Critical - database write performance degraded
```

### Alert 3: Cache Hit Ratio Drop

```
TRIGGER: Cache hit ratio < 95%
WHERE: db.system = postgresql
FREQUENCY: Every 5 minutes
ACTION: Warning - increased disk I/O
```

### Alert 4: Connection Pool Exhaustion

```
TRIGGER: COUNT(pg_stat_activity) > 80% of max_connections
WHERE: service.name = postgresql
FREQUENCY: Every 1 minute
ACTION: Critical - connection pool near limit
```

### Alert 5: Accounting Service Degradation

```
TRIGGER: P95(duration_ms) > 500
WHERE: service.name = accounting
FREQUENCY: Every 1 minute
ACTION: Warning - order processing slowed (database bottleneck)
```

---

## Trace and Log Correlation

### Finding Database-Impacted Traces

1. **Identify slow accounting operations:**

   ```
   WHERE service.name = accounting AND duration_ms > 500
   VISUALIZE TRACES
   ORDER BY duration_ms DESC
   LIMIT 20
   ```

2. **Click on a slow trace** to see:

   - Full trace from checkout → Kafka → accounting → Postgres
   - Long span duration for database INSERT operations
   - Multiple INSERT operations per order
   - Timestamp correlates with high database load

3. **Correlate with database metrics:**
   - Note the timestamp of slow trace
   - Check table sizes at that time
   - Check cache hit ratio at that time
   - Correlation: Large tables + low cache ratio = slow INSERTs

### Example Correlation Flow

1. User completes checkout at `10:15:23`
2. Checkout service creates 2000 Kafka messages (due to `kafkaQueueProblems: 2000`)
3. Accounting service consumes messages starting at `10:15:23`
4. Each message = 3+ database INSERTs
5. Total: 6000+ INSERTs triggered by single checkout
6. Database has 2GB data, cache hit ratio 94%
7. INSERTs take 300ms each (normally 20ms)
8. Accounting service slow to process messages
9. Visible in Honeycomb as slow accounting service spans

**Honeycomb Trace Query:**

```
WHERE service.name = accounting AND duration_ms > 300
VISUALIZE TRACES
```

Click a trace → See database INSERT spans → Correlate with table size metrics.

---

## Comparison: Postgres vs Other Storage Scenarios

| Aspect                | Postgres (OLTP)         | OpenSearch (Logs)      | Checkout Memory              |
| --------------------- | ----------------------- | ---------------------- | ---------------------------- |
| **Data Type**         | Transactional records   | Logs and traces        | In-memory objects            |
| **Growth Driver**     | Order volume            | Error rate + traffic   | Goroutine leaks              |
| **Growth Pattern**    | Cumulative, persistent  | Cumulative, persistent | Temporary, resets on restart |
| **I/O Pattern**       | Read + Write (OLTP)     | Write-heavy (append)   | Memory-only                  |
| **Pressure Type**     | Disk + IOPS             | Disk space             | Memory                       |
| **Degradation**       | Query latency           | Search slowness        | OOM crash                    |
| **Production Analog** | RDS/Aurora under load   | CloudWatch Logs, ELK   | Container memory limits      |
| **Observable**        | Cache ratio, query time | Index size, disk usage | Heap metrics, GC             |
| **Recovery**          | Cleanup/archival needed | Delete old indices     | Restart clears               |

---

## Troubleshooting

### Database Not Growing

**Check if accounting service is running:**

```bash
kubectl get pod -n otel-demo | grep accounting
```

**Check if orders are being processed:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=accounting | grep -i "order received"
```

**Check Kafka connectivity:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=accounting | grep -i kafka
```

**Verify flag is enabled:**

- Go to FlagD UI: http://localhost:4000
- Check `kafkaQueueProblems` is set to `on` with value `100` (optimal for 120Mi)

**Check for OOM kills (accounting service is likely culprit):**

```bash
# Check for OOM events
kubectl get events -n otel-demo | grep OOM

# Check accounting service (120Mi - main bottleneck)
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=accounting | grep -i oom

# Check postgres (usually not the problem)
kubectl describe pod -n otel-demo postgresql-0 | grep -i oom
```

**If accounting service is OOM killing:**

- **REDUCE flag value**: 100 → 50 or even 25
- **REDUCE users**: 12 → 8 or even 5
- **STOP current load test** and restart with lower settings
- The accounting service (120Mi) is the bottleneck, not Postgres

### Database Growing Too Slowly

**With 120Mi accounting service, you have limited headroom:**

**Option 1: Slightly increase flag value (carefully):**

- Current: 100 → Try: 125-150 (maximum safe)
- Monitor **accounting service** memory with `kubectl top pod`
- If accounting memory approaches 110Mi, immediately reduce

**Option 2: Slightly increase traffic (carefully):**

- Current: 12 users → Try: 15 users (maximum)
- Monitor for OOM events on **accounting service**
- Goal is disk growth, not memory exhaustion

**⚠️ Don't go higher:**

- Accounting service with 120Mi memory is the bottleneck
- Values above 150/15 will cause OOM
- Be patient - this scenario takes 4-5 hours with safe settings

### Not Seeing I/O Pressure

**Database may be cached in memory:**

- Postgres container has 80MB memory limit
- Most data may fit in cache
- Try running longer to accumulate more data

**Reduce Postgres memory limit:**

```bash
# Lower memory limit to force more disk I/O
kubectl set resources statefulset postgresql -n otel-demo --limits=memory=40Mi

# Watch for increased I/O pressure
kubectl top pod -n otel-demo | grep postgresql
```

**Check disk I/O is being measured:**

- Verify Postgres metrics are flowing to Honeycomb
- Check if `blk_read_time` and `blk_write_time` are increasing

### Connection Pool Exhausted

**Check current connections:**

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT count(*) FROM pg_stat_activity WHERE datname='otel';"
```

**Increase max connections (temporary fix):**

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -c "ALTER SYSTEM SET max_connections = 200;"
kubectl rollout restart statefulset postgresql -n otel-demo
```

---

## Cleanup

### Stop Load Test

1. Go to Locust UI: http://localhost:8089
2. Click **"Stop"** button

### Disable Feature Flag

1. Go to FlagD UI: http://localhost:4000
2. Set `kafkaQueueProblems` back to **`off`**

### Clear Database (to reclaim disk space)

```bash
# Delete and recreate the database
kubectl exec -n otel-demo postgresql-0 -- psql -U root -c "DROP DATABASE IF EXISTS otel;"
kubectl exec -n otel-demo postgresql-0 -- psql -U root -c "CREATE DATABASE otel;"

# Or delete the PVC to clear all data
kubectl delete pvc postgresql-data -n otel-demo
kubectl delete pod postgresql-0 -n otel-demo
# StatefulSet will recreate with fresh volume
```

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **Database disk growth** from high transaction volume
2. ✅ **I/O pressure patterns** (read/write latency increasing)
3. ✅ **Cache effectiveness degradation** under load (via `postgresql.blks_hit` / `postgresql.blks_read` ratio)
4. ✅ **Query latency correlation** with table size
5. ✅ **Transactional workload impact** on storage (via `postgresql.tup_inserted` metrics)
6. ✅ **Database metrics in Honeycomb** using OpenTelemetry PostgreSQL receiver
7. ✅ **Application-level observability** of database bottlenecks
8. ✅ **Trace correlation** showing database as bottleneck
9. ✅ **Real-world RDS/Aurora** performance patterns
10. ✅ **Unified observability** - database metrics, application traces, and infrastructure metrics in one platform

---

## Key Takeaways

### For Database Administrators:

- **Monitor table growth** proactively (not just database size)
- **Cache hit ratio** is critical indicator of I/O pressure
- **Write latency** degradation appears before disk exhaustion
- **Index bloat** contributes significantly to disk usage
- **Connection pool** sizing matters under sustained load

### For Application Engineers:

- **Async processing** (Kafka → accounting) doesn't eliminate database pressure
- **Batch writes** could reduce I/O pressure (vs one-by-one INSERTs)
- **Database latency** impacts upstream services even when async
- **Monitoring both app and DB** metrics provides complete picture

### For SREs/Platform Engineers:

- **Disk IOPS** can be bottleneck before disk space
- **Sustained write workloads** behave differently than read-heavy
- **Database growth** is cumulative (unlike memory which resets)
- **Alerting on growth rate** catches issues before outages
- **RDS IOPS limits** can cause similar patterns in production

---

## Production Scenarios Simulated

This demo replicates these real-world issues:

1. **RDS Disk Exhaustion** - High transaction volume fills database
2. **IOPS Quota Exceeded** - Sustained writes hit I/O limits
3. **EBS Volume Growth** - Database volume approaching capacity
4. **Cache Pressure** - Working set exceeds available memory
5. **Query Degradation** - Large tables slow down queries
6. **Write Amplification** - Each transaction creates multiple rows

---

## Next Steps

### Extend the Use Case

1. **Enhance database monitoring:**

   - ✅ **Already configured:** PostgreSQL receiver exports metrics to Honeycomb
   - **Add:** Monitor `pg_stat_statements` for slow query analysis
   - **Add:** Track index usage and bloat metrics
   - **Add:** Create custom queries in Honeycomb correlating `postgresql.blks_read` with application latency

2. **Implement archival strategy:**

   - Partition tables by date
   - Archive old orders to S3/object storage
   - Demonstrate cleanup and recovery

3. **Test with read queries:**

   - Add query workload to accounting service
   - Observe read latency under disk pressure
   - Compare read vs write performance

4. **Simulate IOPS limits:**

   - Use `ionice` to limit I/O bandwidth
   - Observe behavior under throttled I/O
   - More realistic RDS/EBS simulation

5. **Create SLO for database performance:**
   - Define acceptable query latency (e.g., P95 < 100ms)
   - Track error budget burn during growth
   - Demonstrate capacity planning

---

## References

- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [OpenTelemetry Collector PostgreSQL Receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/postgresqlreceiver)
- [Honeycomb Query Language](https://docs.honeycomb.io/query-data/)
- [PostgreSQL Statistics Collector](https://www.postgresql.org/docs/current/monitoring-stats.html)
- [AWS RDS Performance Insights](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.html)
- [OpenTelemetry Database Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/database/)
- [PostgreSQL pg_stat_database View](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW)

---

## Summary

This use case demonstrates **Postgres disk and IOPS pressure** using:

- ✅ **High user load (200 users)** - simple, effective, no flags needed
- ✅ Zero code changes required
- ✅ Realistic OLTP workload simulation
- ✅ **Native PostgreSQL metrics in Honeycomb** via OpenTelemetry Collector PostgreSQL receiver
- ✅ **Direct database observability**: cache hit ratio (`postgresql.blks_hit` / `postgresql.blks_read`), write volume (`postgresql.tup_inserted`), deadlocks
- ✅ Cumulative, persistent growth (unlike memory scenarios)
- ✅ I/O pressure patterns similar to RDS/Aurora
- ✅ Trace correlation showing database bottlenecks
- ✅ Dashboard with database metrics, latency trends, and cache metrics in one view
- ✅ Alert configuration for capacity and performance
- ✅ Simulates production storage/IOPS constraints
- ✅ **Unified observability**: Database metrics + Application traces + Infrastructure metrics all in Honeycomb

**Key difference from memory scenarios:** This demonstrates **persistent storage growth and I/O pressure** rather than temporary memory exhaustion - a critical pattern for database capacity planning and performance troubleshooting.

**Key observability feature:** The OpenTelemetry Collector's PostgreSQL receiver provides **direct database metrics** (blocks read/hit, tuples inserted/updated/deleted, deadlocks) exported to Honeycomb, eliminating the need for separate database monitoring tools.

**Recommended approach:** **200 users (tested maximum)**, no feature flags, 2-4 hours runtime. For faster results, reduce PostgreSQL memory to 50Mi to achieve nasty IOPS in ~2 hours instead of 4.

**Note:** 200 users is the sweet spot - tested, reliable, and safe. Higher values risk checkout service OOM due to 20Mi memory limit.
