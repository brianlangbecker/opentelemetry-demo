# Database Failure Scenarios

Observability-focused database failure scenarios to demonstrate different types of database problems and how to diagnose them in Honeycomb.

---

## Overview

These scenarios help you distinguish between:
- **Connection exhaustion** vs downstream service problems
- **Query performance issues** vs network latency
- **Table locks** vs application logic problems

Each scenario generates distinct telemetry patterns in Honeycomb.

---

## Scenario 1: Connection Exhaustion

### Purpose
Demonstrate connection pool exhaustion - a common production issue where the database has reached its connection limit.

### What It Does
```bash
./pgbench.sh connection-exhaust
```

- Opens **95 idle connections** (PostgreSQL max_connections = 100)
- Holds connections open for **5 minutes**
- Leaves only ~5 connections available for application services

### Expected Impact

**PostgreSQL:**
- Connection count: 95-100 (near max)
- CPU: Low (connections are idle)
- Memory: Stable

**accounting service:**
- Error: `FATAL: sorry, too many clients already`
- Unable to process orders from Kafka
- Kafka message backlog grows

**Honeycomb Queries:**

**Connection Count:**
```
Dataset: Metrics
WHERE service.name = "postgresql"
Calculate: MAX(db.connection.count)
Time: Last 10 minutes
```
Expected: Near 100

**Accounting Errors:**
```
Dataset: accounting
WHERE exception.message contains "too many clients"
Calculate: COUNT
Time: Last 10 minutes
```
Expected: Multiple errors

**Key Insight:** High error rate with LOW database CPU/memory indicates connection exhaustion, not database overload.

---

## Scenario 2: Table Lock

### Purpose
Simulate a blocking query that locks a critical table, demonstrating query-level issues vs network problems.

### What It Does
```bash
./pgbench.sh table-lock
```

- Acquires **ACCESS EXCLUSIVE LOCK** on pgbench_accounts table
- Holds lock for **3 minutes**
- Blocks all other queries attempting to access the table

### Expected Impact

**PostgreSQL:**
- Lock: pgbench_accounts table fully locked
- Blocked queries: All queries waiting on lock
- CPU: Low (queries are blocked, not executing)

**Application services:**
- Queries timeout waiting for lock
- No connection errors (connections available)
- Query duration spikes dramatically

**Honeycomb Queries:**

**Query Duration During Lock:**
```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: P95(duration_ms), P99(duration_ms), MAX(duration_ms)
Time: Last 10 minutes
```
Expected: P99 > 30,000ms (30+ seconds)

**Blocked Query Pattern:**
```
Dataset: accounting
WHERE db.system = "postgresql" AND duration_ms > 10000
Calculate: COUNT
Breakdown: db.statement
```
Expected: All queries on locked table are slow

**Check Active Locks in PostgreSQL:**
```bash
kubectl exec -n otel-demo <POD> -- psql -U root otel -c "
  SELECT
    locktype,
    relation::regclass,
    mode,
    granted,
    pid
  FROM pg_locks
  WHERE NOT granted;
"
```

**Key Insight:** High query duration with NO connection errors and LOW CPU indicates blocking/lock contention.

---

## Scenario 3: Slow Query / Full Table Scan

### Purpose
Demonstrate expensive query patterns that cause CPU saturation and slow response times.

### What It Does
```bash
./pgbench.sh slow-query
```

- Runs **full table scans** with aggregations
- Performs **cross joins** (expensive operations)
- Executes **large sorts** on entire tables
- 20 concurrent clients for 5 minutes

### Expected Impact

**PostgreSQL:**
- CPU: 80-100% (heavy computation)
- Memory: Increasing (sort buffers, work_mem)
- Query time: 100ms-1000ms per query (vs <5ms normally)

**Application services:**
- Slow responses (not timeouts)
- All database operations affected
- No connection errors

**Honeycomb Queries:**

**Query Performance Breakdown:**
```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: P95(duration_ms), COUNT
Breakdown: db.statement
Orders: P95(duration_ms) DESC
Time: Last 10 minutes
```
Expected: All queries slower, but still completing

**Database CPU Correlation:**
```
Dataset: Metrics
WHERE service.name = "postgresql"
Calculate: AVG(system.cpu.utilization)
Time: Last 10 minutes (1-minute intervals)
```
Expected: 80-100% CPU during test

**Query Pattern Analysis:**
```
Dataset: accounting
WHERE db.system = "postgresql" AND duration_ms > 100
Calculate: HEATMAP(duration_ms)
Time: Last 10 minutes
```
Expected: Consistent slowdown across all queries

**Key Insight:** High CPU + slow queries (but no errors) indicates query performance issues, not connection or lock problems.

---

## Comparison Matrix

| Symptom | Connection Exhaustion | Table Lock | Slow Query |
|---------|----------------------|------------|------------|
| **Connection errors** | ✅ Yes | ❌ No | ❌ No |
| **Query timeouts** | ✅ Yes | ✅ Yes | ⚠️  Rare |
| **High CPU** | ❌ No | ❌ No | ✅ Yes |
| **Query duration** | N/A (can't connect) | 🔥 Very high | ⚠️  Moderate |
| **Error rate** | 🔥 Very high | ⚠️  Medium | ⚠️  Low |
| **Blocked queries** | ❌ No | ✅ Yes | ❌ No |

---

## Observability Patterns

### 1. Connection Exhaustion Pattern
```
Metrics:
  - db.connection.count → 100 (max)
  - system.cpu.utilization → Low (<30%)
  - system.memory.usage → Stable

Traces:
  - exception.message: "too many clients already"
  - db.system: "postgresql"
  - Error rate: High (50%+)

Diagnosis: Connection pool exhausted, not database overload
```

### 2. Table Lock Pattern
```
Metrics:
  - system.cpu.utilization → Low (<30%)
  - No connection errors
  - Query count drops (blocked)

Traces:
  - duration_ms → 30,000+ (30 seconds+)
  - All queries to locked table are slow
  - No errors, just timeouts

Diagnosis: Lock contention, not performance issue
```

### 3. Slow Query Pattern
```
Metrics:
  - system.cpu.utilization → Very high (80-100%)
  - db.connection.count → Normal
  - Memory climbing

Traces:
  - duration_ms → 100-1000ms (10-100x normal)
  - All queries affected
  - No errors, just slow

Diagnosis: Query optimization needed
```

---

## Demo Script

Perfect for showing database observability:

```bash
cd infra/pgbench/

# 1. Open Honeycomb dashboard (PostgreSQL + accounting datasets)

# 2. Run connection exhaustion
echo "y" | ./pgbench.sh connection-exhaust &

# 3. Show in Honeycomb:
#    - Connection count at max
#    - "too many clients" errors
#    - Low CPU (proves it's not overload)

# 4. Wait for completion, then run table lock
./pgbench.sh table-lock

# 5. Show in Honeycomb:
#    - Query duration spikes
#    - No connection errors
#    - Blocked query pattern

# 6. Finally run slow query
echo "y" | ./pgbench.sh slow-query &

# 7. Show in Honeycomb:
#    - CPU saturation
#    - All queries slow
#    - No errors, just performance degradation
```

---

## Honeycomb Dashboard Recommendations

### Dashboard: Database Health
```
Row 1: Resource Metrics
- PostgreSQL CPU usage
- PostgreSQL memory usage
- Connection count (current/max)

Row 2: Query Performance
- P95 query duration by statement
- Query count (TPS)
- Error rate by error type

Row 3: Failure Patterns
- Connection errors (COUNT)
- Query timeouts (duration_ms > 10000)
- Blocked queries (from pg_locks)
```

### Key Derived Columns

**Connection Exhaustion Indicator:**
```
LTE(DIVIDE($db.connection.count, $db.connection.max), 0.05)
```
True when < 5% connections available

**Query Health:**
```
IF(LTE($duration_ms, 100), "healthy",
   IF(LTE($duration_ms, 1000), "degraded", "critical"))
```

**Error Classification:**
```
IF(CONTAINS($exception.message, "too many clients"), "connection_exhaustion",
   IF(GT($duration_ms, 30000), "possible_lock",
      IF(GT($duration_ms, 1000), "slow_query", "other")))
```

---

## Post-Scenario Analysis

After running each scenario, analyze:

1. **Time to detection:** How long until metrics showed the problem?
2. **Symptom clarity:** Could you distinguish the root cause?
3. **Blast radius:** Which services were affected?
4. **Recovery time:** How long to return to normal?

---

## Best Practices

1. **Run scenarios separately** - Don't overlap tests
2. **Monitor before starting** - Establish baseline metrics
3. **Wait between tests** - Allow full recovery (~5 minutes)
4. **Check pod status** - Ensure PostgreSQL pod is healthy
5. **Clean up after** - Run `./pgbench.sh clean` when done

---

## Troubleshooting

### Connection Exhaustion Won't Trigger
```bash
# Check current connection count
kubectl exec -n otel-demo <POD> -- psql -U root otel -c \
  "SELECT count(*) FROM pg_stat_activity;"

# Check max_connections
kubectl exec -n otel-demo <POD> -- psql -U root otel -c \
  "SHOW max_connections;"
```

### Table Lock Doesn't Block
```bash
# Verify lock is active
kubectl exec -n otel-demo <POD> -- psql -U root otel -c \
  "SELECT * FROM pg_locks WHERE relation = 'pgbench_accounts'::regclass;"
```

### Slow Query Not Slow Enough
```bash
# Increase table size for more expensive queries
./pgbench.sh clean
kubectl exec -n otel-demo <POD> -- pgbench -i -s 200 -U root otel
./pgbench.sh slow-query
```

---

## Summary

| Scenario | Command | Duration | Purpose |
|----------|---------|----------|---------|
| Connection exhaustion | `./pgbench.sh connection-exhaust` | 5 min | Distinguish pool exhaustion from overload |
| Table lock | `./pgbench.sh table-lock` | 3 min | Show blocking vs performance issues |
| Slow query | `./pgbench.sh slow-query` | 5 min | Demonstrate query optimization needs |

---

**These scenarios help you build muscle memory for diagnosing database issues in production!** 🔍🗃️
