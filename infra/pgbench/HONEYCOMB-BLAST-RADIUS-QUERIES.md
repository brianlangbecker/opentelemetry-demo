# Honeycomb Blast Radius Analysis - Query Guide

Complete guide to querying Honeycomb to trace database issues through the entire service dependency chain.

---

## Overview

When database issues occur, they cascade through multiple services:

```
PostgreSQL → Accounting → Kafka → Checkout → Frontend
```

This guide shows you exactly which Honeycomb queries to run to trace the **blast radius** from database to user experience.

---

## The Investigation Flow

### Start: User Reports Slow Checkout
1. Confirm the symptom (checkout latency)
2. Identify the bottleneck (Kafka producer)
3. Trace to consumer (accounting service)
4. Find root cause (database issue)

---

## Layer 1: User-Facing Service (Checkout)

### Query 1: Checkout Service Overall Latency

**Purpose:** Confirm user-facing performance degradation

```
Dataset: checkout
WHERE name = "oteldemo.CheckoutService/PlaceOrder"
Calculate: P50(duration_ms), P95(duration_ms), P99(duration_ms), MAX(duration_ms)
Time: Last 2 hours
```

**Query URL:** https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/7AfTcmyti5A

**What to look for:**
- **Normal:** P50 < 100ms, P95 < 500ms
- **Degraded:** P50 > 1,000ms, P95 > 2,000ms
- **Critical:** P50 > 2,000ms, MAX > 5,000ms

**Example Results (During Database Bloat):**
```
P50:   1,677ms  (40x slower than normal!)
P95:   3,962ms
P99:   4,905ms
MAX:   7,800ms
```

**Interpretation:**
- If latency is high but no errors, look for downstream bottlenecks
- Check Kafka producer duration next

---

### Query 2: Checkout Latency Over Time

**Purpose:** See when degradation started

```
Dataset: checkout
WHERE name = "oteldemo.CheckoutService/PlaceOrder"
Calculate: P95(duration_ms), COUNT
Granularity: 1 minute
Time: Last 24 hours
```

**Query URL:** https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/pcpDyQBdhnH

**What to look for:**
- Sudden spikes in latency
- Correlation with pgbench runs
- Time correlation with database issues

**Example Pattern:**
```
Before 02:00: P95 ~200ms (normal)
After 02:00:  P95 ~4,000ms (degraded)
```

---

## Layer 2: Message Producer (Checkout → Kafka)

### Query 3: Kafka Producer Duration

**Purpose:** Identify if Kafka publish is the bottleneck

```
Dataset: checkout
WHERE messaging.operation = "publish"
  AND messaging.destination.name = "orders"
Calculate: P95(messaging.kafka.producer.duration_ms),
           P99(messaging.kafka.producer.duration_ms),
           MAX(messaging.kafka.producer.duration_ms)
Time: Last 2 hours
```

**Query URL:** https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/rUQTsn2LwKn

**What to look for:**
- Does Kafka producer duration match overall checkout latency?
- If YES: Problem is downstream (Kafka/accounting)
- If NO: Problem is in checkout itself

**Example Results (During Database Bloat):**
```
P95:   3,880ms  (matches checkout latency!)
P99:   4,827ms
MAX:   7,765ms
```

**Interpretation:**
- Kafka publish takes 4-8 seconds (normally <100ms)
- This accounts for almost all of checkout latency
- Bottleneck is in Kafka or its consumer (accounting)

---

### Query 4: Kafka Producer Success Rate

**Purpose:** Determine if messages are failing or just slow

```
Dataset: checkout
WHERE messaging.operation = "publish"
Calculate: COUNT, P95(duration_ms)
Breakdown: messaging.kafka.producer.success
Time: Last 2 hours
```

**Query URL:** https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/CeWHuPF2F88

**What to look for:**
- 100% success rate = slow but working (backpressure)
- Failures = Kafka broker issues or network problems

**Example Results:**
```
Success: 21,814 messages (100%)
P95:     3,882ms
```

**Interpretation:**
- No failures, just extreme slowness
- This is **backpressure** - consumer can't keep up
- Next: Check accounting service

---

## Layer 3: Message Consumer (Accounting Service)

### Query 5: Accounting Database Query Performance

**Purpose:** Check if accounting is slow due to database issues

```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: MAX(duration_ms), P95(duration_ms), COUNT
Time: Last 2 hours
```

**Query URL:** https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/accounting/result/pPfKQbE1faJ

**What to look for:**
- **Normal:** P95 < 10ms, MAX < 100ms
- **Slow queries:** P95 > 100ms, MAX > 1,000ms
- **Critical:** MAX > 10,000ms (10+ seconds)

**Example Results (During Database Bloat):**
```
COUNT: 48,785 queries
P95:   2.72ms
MAX:   30,027ms (30 seconds!)
```

**Interpretation:**
- Most queries are fast (P95 = 2.72ms)
- But some queries take 30+ seconds
- This causes Kafka consumer lag
- Next: Check which queries are slow

---

### Query 6: Accounting Slow Query Breakdown

**Purpose:** Identify which SQL statements are slow

```
Dataset: accounting
WHERE db.system = "postgresql" AND duration_ms > 100
Calculate: COUNT, P95(duration_ms), MAX(duration_ms)
Breakdown: db.statement
Orders: MAX(duration_ms) DESC
Limit: 10
Time: Last 2 hours
```

**What to look for:**
- Which SQL statements have MAX > 1,000ms?
- Are they INSERT, SELECT, UPDATE?
- This tells you what operations are blocked

**Example Results (During Table Lock):**
```
Statement: INSERT INTO "order"... batch of 9 orders
MAX:       30,014ms (30 seconds!)
COUNT:     4 queries blocked
```

**Interpretation:**
- INSERT statements are blocked
- Likely table lock or resource contention
- Next: Check database itself

---

### Query 7: Accounting Error Rate

**Purpose:** Check if database errors are occurring

```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: COUNT
Breakdown: error, exception.type
Time: Last 2 hours
```

**What to look for:**
- **Connection errors:** "too many clients" = connection exhaustion
- **Timeout errors:** = lock contention or slow queries
- **No errors but slow:** = resource constraints (memory, disk I/O)

**Example Results (During Table Lock):**
```
Errors:    18
Successes: 7,686
Error %:   0.23%
Types:     Npgsql.PostgresException, System.InvalidOperationException
```

**Interpretation:**
- Low error rate but high latency
- Not connection exhaustion (would be >50% errors)
- Likely lock contention or resource issue

---

## Layer 4: Database (PostgreSQL)

### Query 8: PostgreSQL Resource Metrics

**Purpose:** Check database CPU, memory, disk I/O

```
Dataset: opentelemetry-demo (metrics)
WHERE service.name = "postgresql"
Calculate: MAX(system.cpu.utilization),
           MAX(system.memory.usage),
           MAX(system.filesystem.usage)
Granularity: 1 minute
Time: Last 2 hours
```

**What to look for:**
- **CPU > 80%:** Query performance issue (full table scans)
- **Memory high:** Potential memory pressure
- **Disk usage > 50%:** Potential bloat issue

**Note:** If metrics aren't available, check directly via kubectl:
```bash
# Check database size
kubectl exec -n otel-demo <POD> -c postgresql -- \
  psql -U root otel -c "SELECT pg_size_pretty(pg_database_size('otel'));"

# Check table sizes
kubectl exec -n otel-demo <POD> -c postgresql -- \
  psql -U root otel -c "SELECT tablename, pg_size_pretty(pg_total_relation_size('public.'||tablename)) FROM pg_tables WHERE schemaname = 'public' ORDER BY pg_total_relation_size('public.'||tablename) DESC LIMIT 10;"

# Check disk usage
kubectl exec -n otel-demo <POD> -c postgresql -- \
  df -h /var/lib/postgresql/data
```

---

## Putting It All Together: Diagnosis Decision Tree

### Step 1: Confirm User Impact
Run Query 1 (Checkout latency)
- Normal (<100ms P50)? → No issue, stop here
- Degraded (>1s P50)? → Continue to Step 2

### Step 2: Identify Bottleneck
Run Query 3 (Kafka producer duration)
- Matches checkout latency? → Bottleneck is Kafka/downstream (Step 3)
- Much lower than checkout? → Bottleneck is in checkout itself (check other checkout spans)

### Step 3: Check Message Consumer
Run Query 5 (Accounting database performance)
- MAX > 10s? → Database issue (Step 4)
- Errors > 10%? → Check error type:
  - "too many clients" → Connection exhaustion (see DATABASE-FAILURE-SCENARIOS.md)
  - Timeout errors → Lock contention (Step 4)

### Step 4: Diagnose Database Root Cause
Run Query 8 (PostgreSQL metrics) or kubectl checks

**High CPU (>80%):**
- Root Cause: Expensive queries (full table scans)
- See: DATABASE-FAILURE-SCENARIOS.md → Slow Query scenario

**Low CPU (<30%) + High query duration:**
- Root Cause: Lock contention
- See: DATABASE-FAILURE-SCENARIOS.md → Table Lock scenario

**Normal CPU + Large database size:**
- Root Cause: Database bloat, memory pressure
- See: DATABASE-BLOAT-INCIDENT.md

**Connection errors:**
- Root Cause: Connection pool exhaustion
- See: DATABASE-FAILURE-SCENARIOS.md → Connection Exhaustion scenario

---

## Common Patterns and Signatures

### Pattern 1: Database Bloat (What We Found)

**Signature:**
```
✅ Checkout P50 > 1,000ms
✅ Kafka producer duration matches checkout latency
✅ Accounting P95 normal (<10ms) but MAX very high (>10s)
✅ Low CPU usage (<50%)
✅ Database size > 1GB
❌ No errors or very low error rate (<1%)
```

**Root Cause:** Database larger than available memory, causing disk I/O

**Fix:** Clean up test data, reduce database size

---

### Pattern 2: Table Lock Contention

**Signature:**
```
✅ Checkout P50 > 1,000ms
✅ Accounting MAX duration > 30s
✅ Low CPU usage
✅ Specific SQL statements blocked
❌ No connection errors
```

**Root Cause:** Table lock holding exclusive access

**Fix:** Release lock, optimize query patterns

---

### Pattern 3: Connection Exhaustion

**Signature:**
```
✅ High error rate (>50%)
✅ "too many clients" errors
✅ Low CPU usage
❌ Checkout may or may not be slow (depends on retry logic)
```

**Root Cause:** max_connections reached

**Fix:** Close idle connections, increase pool size

---

### Pattern 4: Slow Query / CPU Saturation

**Signature:**
```
✅ Checkout P50 > 500ms
✅ All accounting queries slow (not just MAX)
✅ High CPU usage (>80%)
❌ No specific statements blocked
```

**Root Cause:** Expensive queries (full table scans)

**Fix:** Add indexes, optimize queries

---

## Quick Reference: Query URLs

All queries in one place for easy access:

| Query | Purpose | URL |
|-------|---------|-----|
| Checkout latency | User-facing impact | https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/7AfTcmyti5A |
| Checkout over time | When did it start? | https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/pcpDyQBdhnH |
| Kafka producer duration | Is Kafka the bottleneck? | https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/rUQTsn2LwKn |
| Kafka producer success | Failing or just slow? | https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/checkout/result/CeWHuPF2F88 |
| Accounting database perf | Is database slow? | https://ui.honeycomb.io/beowulf/environments/otel-demo/datasets/accounting/result/pPfKQbE1faJ |

---

## Advanced: Creating Derived Columns

### 1. Performance Health Status

```
IF(LTE($duration_ms, 100), "healthy",
   IF(LTE($duration_ms, 1000), "degraded", "critical"))
```

Use in GROUP BY to see distribution of health states

### 2. Error Classification

```
IF(CONTAINS($exception.message, "too many clients"), "connection_exhaustion",
   IF(GT($duration_ms, 30000), "possible_lock",
      IF(GT($duration_ms, 1000), "slow_query", "other")))
```

Automatically categorize error types for faster diagnosis

### 3. Service Health Score

```
IF(AND(LT($duration_ms, 100), NOT($error)), 100,
   IF(LT($duration_ms, 1000), 50, 0))
```

Numeric score for dashboards

---

## Creating a Blast Radius Dashboard

Recommended layout for a single-pane-of-glass view:

### Row 1: User Impact
- Checkout P95 latency (line graph)
- Checkout error rate (line graph)
- Checkout request count (line graph)

### Row 2: Message Layer
- Kafka producer duration P95 (line graph)
- Kafka producer success rate (line graph)
- Kafka message count (line graph)

### Row 3: Consumer Layer
- Accounting database query P95 (line graph)
- Accounting database query MAX (line graph)
- Accounting error count (line graph)

### Row 4: Database Layer
- PostgreSQL CPU usage (line graph)
- PostgreSQL connection count (line graph)
- Database query count (line graph)

**All graphs use the same time range** so you can visually correlate spikes across layers.

---

## Tips for Effective Blast Radius Analysis

### 1. Always Start at the Top
Begin with user-facing services (checkout) and work down the stack. Don't assume you know where the problem is.

### 2. Look for Latency Matching
If checkout latency = Kafka producer duration, the bottleneck is downstream.

### 3. Error Rate Tells a Story
- High errors + low latency = Connection issues
- Low errors + high latency = Resource constraints or locks

### 4. Check Time Correlation
Use matching time ranges across all queries. Look for simultaneous spikes.

### 5. MAX vs P95 Distinction
- High MAX but normal P95 = Intermittent issue (locks, timeouts)
- High P95 and MAX = Systemic issue (resource exhaustion, bad queries)

### 6. Don't Forget Success Rate
100% success with high latency is **backpressure**, not failures.

---

## Related Documentation

- **Incident Report:** [DATABASE-BLOAT-INCIDENT.md](./DATABASE-BLOAT-INCIDENT.md)
- **Failure Scenarios:** [DATABASE-FAILURE-SCENARIOS.md](./DATABASE-FAILURE-SCENARIOS.md)
- **Blast Radius Analysis:** [PGBENCH-BLAST-RADIUS.md](./PGBENCH-BLAST-RADIUS.md)
- **Load Testing:** [POSTGRES-LOAD-TESTING.md](./POSTGRES-LOAD-TESTING.md)

---

**Last Updated:** 2025-11-05
**Use Case:** Tracing database issues through microservices architecture
**Team:** Observability / SRE
