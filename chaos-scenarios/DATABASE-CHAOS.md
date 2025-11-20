# PostgreSQL Database Chaos Scenarios

Comprehensive guide for demonstrating database failures including disk/IOPS pressure, table locks, and performance degradation.

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Scenario 1: Disk & IOPS Pressure](#scenario-1-disk--iops-pressure)
3. [Scenario 2: Table Locks](#scenario-2-table-locks)
4. [Database Pre-Seeding (Optional)](#database-pre-seeding-optional)
5. [Monitoring & Alerts](#monitoring--alerts)

---

## Quick Reference

| Scenario | Method | Duration | Observable Outcome |
|----------|--------|----------|-------------------|
| **IOPS Pressure (Organic)** | 200 users, 4 hours | 2-4 hours | Cache hit ratio degrades, query latency increases |
| **IOPS Pressure (Fast)** | Reduce PostgreSQL memory to 50Mi | 1-2 hours | Faster cache exhaustion |
| **Cache Chaos Demo** | Reduce shared_buffers to 32MB | Immediate | Cache hit ratio drops from 98% to 70-85% |
| **Table Locks** | Lock `order` and `products` tables | 10 minutes | Query timeouts, cascading failures |
| **Pre-seeded IOPS** | Load 150K orders (~200MB) | 10 min setup | Immediate cache pressure |

---

## Scenario 1: Disk & IOPS Pressure

Demonstrate database storage exhaustion and I/O pressure observable through cache hit ratio degradation.

### Option 1: ⭐ Recommended - Organic Growth (2-4 hours)

**Best for realistic production-like patterns:**

**Setup:**
```bash
# 1. Increase accounting service memory first (CRITICAL)
kubectl set resources deployment accounting -n otel-demo \
  --limits=memory=256Mi --requests=memory=128Mi

# 2. Disable kafkaQueueProblems flag
# Go to FlagD UI: http://localhost:4000
# Set kafkaQueueProblems = off (defaultVariant)

# 3. Start load test
# Go to Locust: http://localhost:8089
# Users: 200, Spawn rate: 20, Runtime: 240m
```

**Why this works:**
- ✅ 100% success rate (no errors)
- ✅ Predictable growth (~110MB/hour)
- ✅ Safe for all services
- ✅ Observable IOPS in 2 hours, nasty IOPS in 4 hours

**⚠️ Critical:** Checkout service has only 20Mi memory - **200 users is max safe limit**

---

### Option 2: 🚀 Fast IOPS (1-2 hours)

**Force IOPS pressure faster by reducing cache:**

```bash
# Reduce PostgreSQL memory to force faster cache exhaustion
kubectl set resources deployment postgresql -n otel-demo --limits=memory=50Mi

# Start load: 200 users for 120 minutes
```

**Result:** Nasty IOPS in ~2 hours instead of 4

---

### Option 3: 🎭 Cache Chaos Demo (Immediate)

**Show dramatic performance impact by undersizing the cache:**

```bash
# Reduce shared_buffers from 128MB → 32MB
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=32MB

# Restart to apply
kubectl rollout restart deployment/postgresql -n otel-demo
```

**Expected Results:**
- **Before:** 98-99% cache hit ratio ✅
- **After:** 70-85% cache hit ratio ❌
- **Impact:** 10x increase in disk reads, slower queries

**Timeline:** Immediate - perfect for live demos!

**Restore:**
```bash
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=128MB
kubectl rollout restart deployment/postgresql -n otel-demo
```

---

### Option 4: ⚡ Pre-Seeded IOPS (Instant)

Skip the wait - start with a pre-loaded database. See [Database Pre-Seeding](#database-pre-seeding-optional) below.

---

### Key Metrics (opentelemetry-demo dataset)

#### Cache Hit Ratio (Primary Indicator)

```
WHERE postgresql.blks_hit EXISTS
VISUALIZE
  SUM(INCREASE(postgresql.blks_hit)) /
  (SUM(INCREASE(postgresql.blks_hit)) + SUM(INCREASE(postgresql.blks_read))) * 100
GROUP BY time(5m)
```

**Normal:** 98-99%
**Degraded:** 70-85% (significant IOPS pressure)
**Critical:** <60% (severe IOPS pressure)

#### Database Growth

```
WHERE postgresql.database.size EXISTS
VISUALIZE MAX(postgresql.database.size)
GROUP BY time(10m)
```

**Expected growth:** ~110MB/hour with 200 users

#### Write Volume

```
WHERE postgresql.tup_inserted EXISTS
VISUALIZE SUM(RATE(postgresql.tup_inserted))
GROUP BY time(5m)
```

**Shows:** Insert rate over time

#### Disk I/O Time

```
WHERE postgresql.io.time EXISTS
VISUALIZE SUM(INCREASE(postgresql.io.time))
GROUP BY io_type, time(5m)
```

**Shows:** Time spent on disk reads/writes

---

### Expected Timeline (Option 1: Organic)

| Time | Database Size | Cache Hit Ratio | Observable Behavior |
|------|---------------|----------------|---------------------|
| 0 min | 10 MB | 99%+ | Normal performance |
| 30 min | ~65 MB | 98-99% | Database growing, cache still effective |
| 90 min | ~150 MB | 95-98% | Cache starting to miss |
| 120 min | ~200 MB | 85-95% | **Observable IOPS pressure** |
| 240 min | ~400 MB | 60-80% | **Nasty IOPS - severe degradation** |

---

## Scenario 2: Table Locks

Demonstrate how table locks block database operations and create cascading service failures.

### How to Run

**Using Interactive Script:**
```bash
cd infra/postgres-chaos
./postgres-chaos-scenarios.sh table-lock
```

**Manual Execution:**
```bash
POD=$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n otel-demo $POD -- psql -U root -d otel <<EOF
BEGIN;
LOCK TABLE "order" IN ACCESS EXCLUSIVE MODE;
LOCK TABLE "products" IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(600);  -- 10 minutes
COMMIT;
EOF
```

**Duration:** 10 minutes (600 seconds)

---

### What Happens

**Locks acquired:**
- `order` table → Blocks accounting service (writes)
- `products` table → Blocks product-catalog service (reads)

**Cascading failures:**
```
Table Locks (order + products)
    ├─→ order table locked
    │       ↓
    │   accounting: INSERT blocked → timeouts
    │       ↓
    │   checkout: Order placement fails
    │
    └─→ products table locked
            ↓
        product-catalog: SELECT blocked → timeouts
            ↓
        checkout: Product lookup fails
            ↓
        frontend: Product pages fail
```

---

### Observable Patterns

#### Accounting Blocked Queries

```
WHERE service.name = "accounting"
  AND db.system = "postgresql"
  AND db.statement CONTAINS "order"
VISUALIZE P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
```

**Expected:** P99 > 30,000ms (30+ seconds) - queries timing out

#### Product-Catalog Blocked Queries

```
WHERE service.name = "product-catalog"
  AND db.system = "postgresql"
  AND db.statement CONTAINS "products"
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

**Expected:** P99 > 30,000ms

#### Compare Both Services

```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.system = "postgresql"
  AND duration_ms > 10000
VISUALIZE COUNT
GROUP BY service.name, time(1m)
```

#### Frontend Impact

```
WHERE service.name = "frontend"
  AND http.status_code >= 500
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** Error rate increases (product pages fail)

---

### Key Indicators

**What you'll see:**
- ✅ Query duration: 30,000+ ms (timeouts)
- ✅ No connection errors (connections work, queries block)
- ✅ Low CPU (<30%) - queries waiting, not executing
- ✅ Both services affected: accounting + product-catalog

**What you won't see:**
- ❌ Connection errors ("too many clients")
- ❌ High CPU (queries blocked, not running)
- ❌ All queries slow (only locked tables affected)

---

### Verify Locks Are Active

**Check active locks:**
```bash
kubectl exec -n otel-demo $POD -- psql -U root otel -c "
  SELECT locktype, relation::regclass as table_name, mode, granted
  FROM pg_locks
  WHERE locktype = 'relation'
    AND relation IN ('order'::regclass, 'products'::regclass);
"
```

**Check waiting queries:**
```bash
kubectl exec -n otel-demo $POD -- psql -U root otel -c "
  SELECT pid, wait_event_type, query
  FROM pg_stat_activity
  WHERE wait_event_type = 'Lock';
"
```

---

## Database Pre-Seeding (Optional)

Pre-populate the database with 150,000 orders (~200 MB) to demonstrate immediate IOPS pressure without waiting hours.

### Why Seed?

**Without Seeding:**
- Empty database (10 MB)
- Wait 2-4 hours for organic growth
- Cache hit ratio stays at 99%+ for hours

**With Seeding:**
- Start with 150,000 orders (200 MB)
- Database exceeds cache size immediately
- **Instant IOPS pressure** with cache hit ratio at ~85-90%

---

### Prerequisites

- PostgreSQL persistent storage configured
- PostgreSQL memory set to 300Mi (required for stability)
- 5-10 minutes for setup

---

### Step 1: Create Persistent Volume

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
  namespace: otel-demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
```

---

### Step 2: Attach PVC to PostgreSQL

```bash
kubectl patch deployment postgresql -n otel-demo --type=strategic --patch '
spec:
  template:
    spec:
      containers:
      - name: postgresql
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: postgresql-data
        persistentVolumeClaim:
          claimName: postgresql-data
'
```

**Wait for restart:**
```bash
kubectl get pods -n otel-demo -l app.kubernetes.io/name=postgresql -w
```

---

### Step 3: Create Seed Script

Save this to `seed-150k.sql`:

```sql
-- Seed 150,000 orders for IOPS demo
DO $$
DECLARE
  batch_size INT := 1000;
  total_orders INT := 150000;
  current_batch INT := 0;
BEGIN
  WHILE current_batch < total_orders LOOP
    INSERT INTO "order" (order_id, user_id, currency_code, created_at)
    SELECT
      gen_random_uuid(),
      'user_' || ((current_batch + i) % 10000),
      'USD',
      NOW() - (random() * interval '90 days')
    FROM generate_series(1, batch_size) AS i;

    current_batch := current_batch + batch_size;
    RAISE NOTICE 'Inserted % orders...', current_batch;
  END LOOP;
END $$;

VACUUM ANALYZE "order";
```

---

### Step 4: Execute Seed

```bash
# Copy script to pod
POD=$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl cp seed-150k.sql otel-demo/$POD:/tmp/

# Execute (takes 5-10 minutes)
kubectl exec -n otel-demo $POD -- psql -U root -d otel -f /tmp/seed-150k.sql
```

---

### Step 5: Verify Seeded Data

```bash
# Check database size
kubectl exec -n otel-demo $POD -- psql -U root -d otel -c \
  "SELECT pg_size_pretty(pg_database_size('otel'));"

# Expected: ~200 MB

# Check order count
kubectl exec -n otel-demo $POD -- psql -U root -d otel -c \
  "SELECT COUNT(*) FROM \"order\";"

# Expected: 150,000
```

---

### Step 6: Monitor Cache Hit Ratio

```
WHERE postgresql.blks_hit EXISTS
VISUALIZE
  SUM(INCREASE(postgresql.blks_hit)) /
  (SUM(INCREASE(postgresql.blks_hit)) + SUM(INCREASE(postgresql.blks_read))) * 100
GROUP BY time(5m)
```

**With seeded data:** 85-90% immediately (showing IOPS pressure)
**Without seeded data:** 98-99% (excellent cache hit ratio)

---

## Monitoring & Alerts

### Alert 1: Cache Hit Ratio Degradation

**Query:**
```
WHERE postgresql.blks_hit EXISTS
VISUALIZE
  SUM(INCREASE(postgresql.blks_hit)) /
  (SUM(INCREASE(postgresql.blks_hit)) + SUM(INCREASE(postgresql.blks_read))) * 100
GROUP BY time(5m)
```

**Trigger:**
- **Threshold:** Cache hit ratio < 85%
- **Duration:** For at least 5 minutes
- **Severity:** WARNING

**Notification:**
```
⚠️ PostgreSQL Cache Degradation

Cache Hit Ratio: {{cache_hit_ratio}}%
Normal: 98-99%

Action: Database may exceed cache size - check disk I/O
```

---

### Alert 2: Table Lock Detected

**Query:**
```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.system = "postgresql"
  AND duration_ms > 30000
VISUALIZE COUNT
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** COUNT > 5 queries/minute
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL

**Notification:**
```
🔴 Table Lock Detected

Services: accounting, product-catalog
Blocked Queries: {{COUNT}} queries timing out
Duration: >30 seconds

Action: Check PostgreSQL locks - run pg_locks query
```

---

### Alert 3: Database Growth Rate

**Query:**
```
WHERE postgresql.database.size EXISTS
VISUALIZE MAX(postgresql.database.size)
GROUP BY time(1h)
```

**Trigger:**
- **Threshold:** Growth > 500 MB/hour
- **Severity:** WARNING

**Notification:**
```
⚠️ Rapid Database Growth

Growth Rate: {{growth_rate}} MB/hour
Current Size: {{MAX(postgresql.database.size)}} bytes

Action: Check for data retention issues or unusual write patterns
```

---

### Alert 4: High Disk I/O Time

**Query:**
```
WHERE postgresql.io.time EXISTS
VISUALIZE SUM(INCREASE(postgresql.io.time))
GROUP BY time(5m)
```

**Trigger:**
- **Threshold:** SUM(INCREASE(postgresql.io.time)) > 5000ms per 5min
- **Severity:** WARNING

**Notification:**
```
⚠️ High Disk I/O Time

I/O Time: {{SUM(INCREASE(postgresql.io.time))}}ms
Pattern: Sustained disk I/O pressure

Action: Check cache hit ratio and query performance
```

---

## Comparison Matrix

| Symptom | IOPS Pressure | Table Lock | Connection Exhaustion |
|---------|--------------|------------|----------------------|
| **Cache hit ratio** | ⬇️ Degrades | ➡️ Normal | ➡️ Normal |
| **Query timeouts** | ⚠️ Rare | 🔥 Severe (30s+) | ✅ Yes |
| **Connection errors** | ❌ No | ❌ No | 🔥 Severe |
| **High CPU** | ⚠️ Moderate | ❌ No (blocked) | ❌ No |
| **Disk reads** | ⬆️ Increases | ➡️ Normal | ➡️ Normal |
| **Specific tables** | ❌ All tables | ✅ Locked tables only | ❌ All tables |
| **Duration** | Hours (gradual) | Minutes (sudden) | Minutes (sudden) |

---

## Cleanup

### Stop IOPS Pressure Test

```bash
# Stop Locust load test
# Go to http://localhost:8089 and click "Stop"

# Restore PostgreSQL memory (if changed)
kubectl set resources deployment postgresql -n otel-demo \
  --limits=memory=300Mi

# Restore shared_buffers (if changed)
kubectl set env deployment/postgresql -n otel-demo POSTGRES_SHARED_BUFFERS=128MB
kubectl rollout restart deployment/postgresql -n otel-demo
```

### Table Lock Cleanup

Table locks automatically release after 10 minutes. If you need to release immediately:

```bash
# Find blocking query PID
kubectl exec -n otel-demo $POD -- psql -U root otel -c \
  "SELECT pid FROM pg_stat_activity WHERE query LIKE '%LOCK TABLE%';"

# Terminate the session
kubectl exec -n otel-demo $POD -- psql -U root otel -c \
  "SELECT pg_terminate_backend(<PID>);"
```

---

## Key Takeaways

### IOPS Pressure
- ✅ Cache hit ratio is primary indicator
- ✅ Gradual degradation over hours
- ✅ Four options: organic, fast, chaos demo, pre-seeded
- ✅ Safe max load: 200 concurrent users

### Table Locks
- ✅ Affects specific tables (order, products)
- ✅ Query timeouts (30s+) without connection errors
- ✅ Low CPU (queries blocked, not executing)
- ✅ Cascading failures to dependent services

### Pre-Seeding
- ✅ Instant IOPS pressure demonstration
- ✅ Requires persistent storage
- ✅ 150K orders = ~200 MB = immediate cache pressure
- ✅ 10 minutes setup vs 4 hours wait

---

## Related Scenarios

- [OBSERVABILITY-PATTERNS.md](OBSERVABILITY-PATTERNS.md) - General observability and alerting guide
- [../infra/postgres-chaos/](../infra/postgres-chaos/) - Additional PostgreSQL chaos scenarios

---

**Last Updated:** 2025-11
**Status:** Production-ready chaos scenarios
