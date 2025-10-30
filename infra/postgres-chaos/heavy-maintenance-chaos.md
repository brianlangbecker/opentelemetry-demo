# 🔥 Heavy Maintenance Chaos - 5-10 Minute Sustained Database Stress

## Overview

The **Heavy Maintenance** scenario runs for **5-10 minutes** and simulates a realistic "database under heavy load" situation by cycling through multiple chaos patterns continuously.

**Perfect for:**

- Long-form observability demos
- Testing alert fatigue
- Demonstrating gradual system degradation
- Training on incident response

---

## Timeline & Phases

### **Each Cycle = ~30 seconds** (10-20 cycles total)

```
┌─────────────────────────────────────────────────────┐
│ CYCLE 1 of 10                    (Elapsed: 0:00:30) │
├─────────────────────────────────────────────────────┤
│  Phase 1: Table Lock         (5s)  🔒              │
│  Phase 2: Bloat Generation   (10s) 💥              │
│  Phase 3: Expensive Query    (10s) 🐌              │
│  Phase 4: Row-Level Locks    (5s)  🔐              │
└─────────────────────────────────────────────────────┘
         ⬇️  Repeat for all cycles  ⬇️
```

---

## Phase Breakdown

### **Phase 1: Table Lock (5 seconds)** 🔒

**What happens:**

```sql
LOCK TABLE "order" IN EXCLUSIVE MODE;
-- Hold for 5 seconds
```

**Impact:**

- ✅ Reads can continue
- ❌ ALL writes to `order` table are blocked
- ❌ New orders from accounting service will queue up

**Observable in Honeycomb:**

```
VISUALIZE: COUNT()
WHERE: postgresql.connection.status = 'waiting'
GROUP BY: time(10s)

Expected: Spikes every 30 seconds (one per cycle)
```

---

### **Phase 2: Bloat Generation (10 seconds)** 💥

**What happens:**

```sql
-- Update 200 random orders without changing values
-- Creates ~600 dead tuples per cycle
UPDATE orderitem SET quantity = quantity
WHERE order_id IN (random 200 orders);
```

**Impact:**

- ✅ Creates dead tuples (table bloat)
- ✅ Forces autovacuum to work harder
- ✅ Increases disk I/O for reads (scanning dead tuples)

**Observable in Honeycomb:**

```
VISUALIZE: SUM(INCREASE(postgresql.tup_updated))
GROUP BY: table, time(1m)

Expected: Steady climb ~1200-2400 updates/minute
```

**By End of 10 minutes:**

- **Total dead tuples:** ~12,000 (20 cycles × 600)
- **Bloat percentage:** ~8-10% (if no autovacuum)

---

### **Phase 3: Expensive Query (10 seconds)** 🐌

**What happens:**

```sql
-- Full table scan + aggregation (no index usage)
SELECT o.order_id, COUNT(oi.product_id)
FROM "order" o
LEFT JOIN orderitem oi ON o.order_id = oi.order_id
WHERE o.order_id > '0'  -- Forces sequential scan
GROUP BY o.order_id;
```

**Impact:**

- ✅ High CPU usage
- ✅ Increased cache misses (large data scan)
- ✅ Disk I/O spike (especially if cache is small)

**Observable in Honeycomb:**

```
VISUALIZE:
  MAX(postgresql.blks_read) AS disk_reads,
  AVG($postgresql.cache_hit_ratio) AS cache_ratio
GROUP BY: time(30s)

Expected:
  - Disk reads spike every 30s
  - Cache hit ratio drops during spikes
```

---

### **Phase 4: Row-Level Contention (5 seconds)** 🔐

**What happens:**

```sql
-- Lock 50 random orders for update
SELECT * FROM "order"
WHERE order_id IN (random 50 orders)
FOR UPDATE NOWAIT;
-- Hold locks for 3 seconds
```

**Impact:**

- ✅ Creates row-level lock contention
- ✅ Blocks concurrent updates to the same orders
- ✅ Simulates "hot row" contention

**Observable in Honeycomb:**

```
VISUALIZE: MAX(postgresql.connection.max_age)
WHERE: postgresql.connection.status = 'active'

Expected: Small spikes in transaction age
```

---

## Cumulative Effects Over Time

| **Time** | **Dead Tuples** | **Bloat %** | **Lock Events** | **Slow Queries** | **Disk Reads** |
| -------- | --------------- | ----------- | --------------- | ---------------- | -------------- |
| 1 min    | ~1,200          | ~1%         | 2               | 2                | Moderate       |
| 3 mins   | ~3,600          | ~3%         | 6               | 6                | High           |
| 5 mins   | ~6,000          | ~5%         | 10              | 10               | Very High      |
| 10 mins  | ~12,000         | ~10%        | 20              | 20               | Extreme        |

---

## Honeycomb Dashboard Queries

### **1. Lock Frequency Timeline**

```
DATASET: opentelemetry-demo
TIME RANGE: Last 15 minutes

VISUALIZE: COUNT()
WHERE:
  postgresql.connection.status = 'waiting' OR
  postgresql.connection.status = 'blocked'
GROUP BY: time(30s)

Expected: Spikes every 30 seconds during chaos
```

---

### **2. Dead Tuple Accumulation**

```
DATASET: opentelemetry-demo

VISUALIZE: MAX(postgresql.rows_dead_ratio)
WHERE: postgresql.rows_dead_ratio EXISTS
GROUP BY: table, time(1m)

Expected: Steady climb from 0% to ~8-10%
```

---

### **3. Query Performance Degradation**

```
DATASET: opentelemetry-demo

VISUALIZE:
  P95($postgresql.blks_read) AS p95_disk_reads,
  P95($postgresql.blks_hit) AS p95_cache_hits
GROUP BY: time(1m)

Expected:
  - Disk reads increase steadily (bloat forces more reads)
  - Cache hits plateau or decrease
```

---

### **4. Cache Hit Ratio Degradation**

```
DATASET: opentelemetry-demo

CALCULATED FIELD: cache_ratio
  DIV(
    MUL($postgresql.blks_hit, 100),
    ADD($postgresql.blks_hit, $postgresql.blks_read)
  )

VISUALIZE: AVG(cache_ratio)
GROUP BY: time(1m)

Expected: Gradual decline from ~99% to ~85-90%
```

---

## Running the Scenario

### **Option 1: Interactive Menu**

```bash
cd infra
./run-postgres-chaos.sh

# Choose option 12
# Select duration: 1 (5 min) or 2 (10 min)
```

### **Option 2: Direct Execution (Non-Interactive)**

```bash
# 5-minute version
kubectl exec -n otel-demo <postgres-pod> -- \
  psql -U root -d otel -f /tmp/heavy-maintenance-5min.sql

# 10-minute version
kubectl exec -n otel-demo <postgres-pod> -- \
  psql -U root -d otel -f /tmp/heavy-maintenance-10min.sql
```

---

## Real-Time Monitoring During Chaos

### **Terminal 1: Run Chaos**

```bash
./run-postgres-chaos.sh
# Choose option 12
```

### **Terminal 2: Watch Active Locks**

```bash
watch -n 5 "kubectl exec -n otel-demo <postgres-pod> -- \
  psql -U root -d otel -c 'SELECT COUNT(*), state FROM pg_stat_activity WHERE datname=\"otel\" GROUP BY state;'"
```

### **Terminal 3: Watch Table Bloat**

```bash
watch -n 30 "kubectl exec -n otel-demo <postgres-pod> -- \
  psql -U root -d otel -c 'SELECT relname, n_dead_tup, n_live_tup FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;'"
```

### **Browser: Honeycomb Dashboard**

- Open the queries above in separate panels
- Set auto-refresh to 10 seconds
- Watch the chaos unfold in real-time! 🔥

---

## Cleanup After Chaos

### **1. Check Damage**

```bash
./run-postgres-chaos.sh
# Choose option 8 (Show Table Bloat)
```

**Expected output:**

```
   table   | size  | dead  |  live  | bloat_pct
-----------+-------+-------+--------+-----------
 orderitem | 18 MB | 12000 |  81655 |     12.84
 order     | 21 MB |     0 | 150035 |      0.00
 shipping  | 35 MB |     0 | 150035 |      0.00
```

### **2. Clean Up Bloat**

```bash
./run-postgres-chaos.sh
# Choose option 10 (VACUUM FULL)
```

This will:

- Remove all dead tuples
- Reclaim disk space
- Reset bloat percentage to 0%
- **⚠️ Warning:** May take 1-5 minutes and will lock tables

---

## Learning Outcomes

After running this scenario, teams will understand:

1. **Gradual System Degradation:**

   - How small issues accumulate over time
   - Why continuous monitoring is critical

2. **Lock Contention Patterns:**

   - Difference between table locks and row locks
   - How locks cascade to downstream services

3. **Table Bloat Impact:**

   - How dead tuples affect query performance
   - When and why to run VACUUM

4. **Observability Best Practices:**

   - Setting up alerts for bloat percentage
   - Monitoring lock wait times
   - Tracking query performance trends

5. **Incident Response:**
   - Identifying which phase is causing the most pain
   - Prioritizing what to fix first
   - Using metrics to verify fixes

---

## Pro Tips

### **For Demo Presentations:**

- Start with a clean database (run VACUUM first)
- Run the 5-minute version for time-constrained demos
- Open Honeycomb dashboard BEFORE starting chaos
- Use the "Show Active Locks" option between cycles for narrative

### **For Training Exercises:**

- Run the 10-minute version for more pronounced effects
- Challenge participants to identify which phase causes which metric change
- Have them write alerts that would catch this scenario
- Practice incident response: "What would you investigate first?"

### **For Chaos Engineering:**

- Run during load generator stress test (200 users)
- Combine with the 32MB cache setting for maximum impact
- Monitor accounting service health during chaos
- Test if your alerts fire correctly

---

## Expected Alert Triggers

If you have alerts configured, you should see:

| **Alert**              | **Trigger Time** | **Reason**                |
| ---------------------- | ---------------- | ------------------------- |
| High Lock Wait Time    | ~1 minute        | Table locks every cycle   |
| Bloat Percentage > 5%  | ~3-5 minutes     | Cumulative dead tuples    |
| Cache Hit Ratio < 95%  | ~2-4 minutes     | Expensive queries + bloat |
| Slow Query (>10s)      | Every 30s        | Phase 3 aggregation       |
| Connection Queue Depth | ~2-3 minutes     | Lock waits accumulate     |

---

## Safety Notes

✅ **Safe:**

- Does not corrupt data
- Does not delete anything
- Can be interrupted with Ctrl+C
- Effects are reversible with VACUUM

⚠️ **Impact:**

- Will slow down the accounting service
- May cause order writes to queue up
- Will increase CPU/disk I/O
- Will create ~1 MB of dead tuples per minute

🔴 **Do NOT run in production!**

---

## Summary

The **Heavy Maintenance** scenario is perfect for long-form demos where you want to show:

- How database issues develop over time
- What multiple simultaneous problems look like
- How to use observability tools to diagnose complex issues
- The importance of proactive monitoring and alerting

**Duration:** 5-10 minutes  
**Difficulty:** Moderate to Hard  
**Best For:** Training, long demos, chaos engineering exercises  
**Cleanup:** Required (run VACUUM FULL)

🔥 **Happy Chaos Engineering!** 🔥
