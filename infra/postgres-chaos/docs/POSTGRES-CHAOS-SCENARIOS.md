# PostgreSQL Chaos Testing Scenarios

Observability-focused chaos scenarios demonstrating different types of PostgreSQL failure patterns and how to diagnose them in Honeycomb.

---

## Overview

These chaos scenarios help you distinguish between:

- **Connection exhaustion** vs downstream service problems
- **Query performance issues** vs network latency
- **Table locks** vs application logic problems
- **Direct database consumers** (accounting, product-catalog) vs indirect consumers (checkout, frontend)

Each scenario generates distinct telemetry patterns in Honeycomb and affects multiple services through cascading failures.

---

## Services That Use PostgreSQL

**Direct PostgreSQL Consumers:**

1. **accounting service**

   - Reads/writes `order` and `orderitem` tables
   - Processes Kafka messages and stores order data
   - ~1,246 queries per 30 minutes
   - Technology: .NET/C# with Entity Framework

2. **product-catalog service**
   - Reads `products` table
   - Serves product information to frontend and checkout
   - High read volume during browsing and checkout
   - Technology: Go with database/sql

**Indirect Consumers (via service dependencies):**

- **checkout** → depends on product-catalog for product data
- **frontend** → depends on product-catalog for product listings
- **recommendation** → may query product data

---

## Scenario 1: Connection Exhaustion

### Purpose

Demonstrate connection pool exhaustion - a common production issue where the database has reached its connection limit.

### What It Does

```bash
./postgres-chaos-scenarios.sh connection-exhaust
```

- Opens **95 idle connections** (PostgreSQL max_connections = 100)
- Holds connections open for **5 minutes**
- Leaves only ~5 connections available for all application services

### Expected Impact

**PostgreSQL:**

- Connection count: 95-100 (near max)
- CPU: Low (connections are idle)
- Memory: Stable

**accounting service:**

- Error: `FATAL: sorry, too many clients already`
- Unable to process orders from Kafka
- Kafka message backlog grows
- Order writes fail

**product-catalog service:**

- Error: `could not connect to server` or connection timeouts
- Product queries fail
- Frontend shows "Products unavailable" errors
- Checkout cannot retrieve product information

**checkout service:**

- Cascading failures from product-catalog unavailability
- Cannot validate products during order placement
- User-facing checkout errors

**frontend:**

- Product listing pages fail to load
- Checkout flow broken
- User-visible errors

### Honeycomb Queries

**Connection Count:**

```
Dataset: Metrics
WHERE service.name = "postgresql"
Calculate: MAX(db.connection.count)
Time: Last 10 minutes
```

Expected: Near 100 (at limit)

**Accounting Errors:**

```
Dataset: accounting
WHERE exception.message contains "too many clients"
Calculate: COUNT
Time: Last 10 minutes
```

Expected: Multiple connection errors

**Product-Catalog Errors:**

```
Dataset: product-catalog
WHERE exception.message contains "connect" OR error = true
Calculate: COUNT
Time: Last 10 minutes
```

Expected: High error rate during connection exhaustion

**Checkout Impact:**

```
Dataset: checkout
WHERE rpc.service = "oteldemo.ProductCatalogService"
Calculate: COUNT, P95(duration_ms)
Breakdown: http.status_code
```

Expected: Increased errors and timeouts

**Key Insight:** High error rate with LOW database CPU/memory indicates connection exhaustion, not database overload. Both accounting AND product-catalog fail simultaneously.

---

## Scenario 2: Table Lock

### Quick Reference

📋 **See:** `chaos-scenarios/postgres-table-lock.md` for complete guide with Honeycomb queries and alerts.

### What It Does

```bash
./postgres-chaos-scenarios.sh table-lock
```

- Acquires **ACCESS EXCLUSIVE LOCK** on `order` and `products` tables
- Holds locks for **10 minutes**
- Blocks all queries attempting to access these tables

### Expected Impact

**accounting service:** Cannot write to `order` table → queries timeout (30+ seconds)  
**product-catalog service:** Cannot read from `products` table → queries timeout (30+ seconds)  
**checkout service:** Cascading failures from both services  
**frontend:** Product pages fail to load

**Key Indicators:**
- ✅ Query duration: 30,000+ ms (timeouts)
- ✅ No connection errors (connections work, queries block)
- ✅ Low CPU (<30%) - queries waiting, not executing
- ✅ Both services affected: accounting (order) + product-catalog (products)

**Key Insight:** High query duration with NO connection errors and LOW CPU indicates blocking/lock contention. Different services are affected based on which table they need access to.

---

## Scenario 3: Slow Query / Full Table Scan

### Purpose

Demonstrate expensive query patterns that cause CPU saturation and affect ALL database consumers equally.

### What It Does

```bash
./postgres-chaos-scenarios.sh slow-query
```

- Runs **full table scans** with aggregations on pgbench tables
- Performs **cross joins** (expensive operations)
- Executes **large sorts** on entire tables
- 20 concurrent clients for 5 minutes
- Saturates database CPU and I/O

### Expected Impact

**PostgreSQL:**

- CPU: 80-100% (heavy computation)
- Memory: Increasing (sort buffers, work_mem)
- I/O: High disk reads
- ALL queries slower (shared resource exhaustion)

**accounting service:**

- Moderate slowdown (10-100x normal)
- No errors, just slow responses
- Query time: 5ms → 50-500ms
- Still processes orders, but slowly

**product-catalog service:**

- Moderate to severe slowdown
- Product queries much slower
- Query time: <5ms → 50-200ms
- Frontend pages load slowly
- Checkout product lookups slow

**checkout service:**

- Slower end-to-end checkout flow
- Product lookups take longer
- Overall latency increases
- No hard failures, just degradation

**frontend:**

- Slow page loads (product-catalog impact)
- Slow checkout completion (accounting + product-catalog)
- Degraded user experience, not broken

### Honeycomb Queries

**Accounting Query Performance:**

```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: P50(duration_ms), P95(duration_ms), COUNT
Breakdown: db.statement
Orders: P95(duration_ms) DESC
Time: Last 10 minutes
```

Expected: All queries slower, but still completing

**Product-Catalog Query Performance:**

```
Dataset: product-catalog
WHERE db.system = "postgresql"
Calculate: P50(duration_ms), P95(duration_ms), COUNT
Breakdown: db.statement
Orders: P95(duration_ms) DESC
Time: Last 10 minutes
```

Expected: All queries slower (especially product lookups)

**Database CPU Correlation:**

```
Dataset: Metrics
WHERE service.name = "postgresql"
Calculate: AVG(system.cpu.utilization)
Time: Last 10 minutes (1-minute intervals)
```

Expected: 80-100% CPU during test

**Cross-Service Impact:**

```
Dataset: checkout
Calculate: P95(duration_ms)
Breakdown: rpc.service
Time: Last 10 minutes
```

Expected: Both accounting and product-catalog calls slower

**Query Pattern Analysis:**

```
Dataset: accounting OR product-catalog
WHERE db.system = "postgresql" AND duration_ms > 100
Calculate: HEATMAP(duration_ms)
Breakdown: service.name
Time: Last 10 minutes
```

Expected: Consistent slowdown across BOTH services

**Key Insight:** High CPU + slow queries (but no errors) indicates query performance issues affecting ALL database consumers equally. This is different from table locks which affect specific services.

---

## Comparison Matrix

| Symptom                     | Connection Exhaustion  | Table Lock                        | Slow Query                |
| --------------------------- | ---------------------- | --------------------------------- | ------------------------- |
| **Connection errors**       | ✅ Yes (both services) | ❌ No                             | ❌ No                     |
| **Query timeouts**          | ✅ Yes                 | ✅ Yes (specific tables)          | ⚠️ Rare                   |
| **High CPU**                | ❌ No                  | ❌ No                             | ✅ Yes                    |
| **Query duration**          | N/A (can't connect)    | 🔥 Very high (locked tables only) | ⚠️ Moderate (all queries) |
| **Error rate**              | 🔥 Very high           | ⚠️ Medium (timeouts)              | ⚠️ Low                    |
| **Blocked queries**         | ❌ No                  | ✅ Yes (specific tables)          | ❌ No                     |
| **accounting impact**       | 🔥 Severe              | 🔥 Severe (order table)           | ⚠️ Moderate               |
| **product-catalog impact**  | 🔥 Severe              | 🔥 Severe (products table)        | ⚠️ Moderate               |
| **Affects specific tables** | ❌ No (all or nothing) | ✅ Yes                            | ❌ No (affects all)       |

---

## Service Impact Patterns

### Pattern 1: Symmetric Impact (Connection Exhaustion, Slow Query)

```
PostgreSQL Resource Exhaustion
    ↓
Affects ALL database consumers equally
    ├─→ accounting: Cannot write orders
    └─→ product-catalog: Cannot read products
        ↓
    checkout: Cannot complete orders (needs both services)
        ↓
    frontend: Broken user experience
```

### Pattern 2: Asymmetric Impact (Table Locks)

```
PostgreSQL Table Lock
    ├─→ order table locked
    │       ↓
    │   accounting: Blocked (writes fail)
    │       ↓
    │   checkout: Kafka backlog, slow order confirmation
    │
    └─→ products table locked
            ↓
        product-catalog: Blocked (reads fail)
            ↓
        checkout: Cannot retrieve product info
            ↓
        frontend: Product pages fail
```

---

## Observability Patterns

### 1. Connection Exhaustion Pattern

```
Metrics:
  - db.connection.count → 100 (max)
  - system.cpu.utilization → Low (<30%)
  - system.memory.usage → Stable

Traces (accounting):
  - exception.message: "too many clients already"
  - db.system: "postgresql"
  - Error rate: High (50%+)

Traces (product-catalog):
  - exception.message: "could not connect"
  - db.system: "postgresql"
  - Error rate: High (50%+)

Diagnosis: Connection pool exhausted, not database overload
Impact: BOTH services fail simultaneously
```

### 2. Table Lock Pattern

```
Metrics:
  - system.cpu.utilization → Low (<30%)
  - No connection errors
  - Query count drops (blocked)

Traces (accounting - order table locked):
  - duration_ms → 30,000+ (30 seconds+)
  - db.statement: "INSERT INTO order..."
  - No errors, just timeouts

Traces (product-catalog - products table locked):
  - duration_ms → 30,000+ (30 seconds+)
  - db.statement: "SELECT * FROM products..."
  - No errors, just timeouts

Diagnosis: Lock contention, not performance issue
Impact: Services affected based on which table they access
```

### 3. Slow Query Pattern

```
Metrics:
  - system.cpu.utilization → Very high (80-100%)
  - db.connection.count → Normal
  - Memory climbing

Traces (accounting):
  - duration_ms → 100-500ms (10-100x normal)
  - All queries affected
  - No errors, just slow

Traces (product-catalog):
  - duration_ms → 50-200ms (10-40x normal)
  - All queries affected
  - No errors, just slow

Diagnosis: Query optimization needed OR resource exhaustion
Impact: ALL database consumers affected proportionally
```

---

## Demo Script

Perfect for showing database observability across multiple services:

```bash
cd infra/postgres-chaos/

# 1. Open Honeycomb dashboards
#    - PostgreSQL metrics (CPU, memory, connections)
#    - accounting dataset
#    - product-catalog dataset
#    - checkout dataset

# 2. Run connection exhaustion (5 minutes)
echo "y" | ./postgres-chaos-scenarios.sh connection-exhaust &

# 3. Show in Honeycomb:
#    - Connection count at max
#    - accounting: "too many clients" errors
#    - product-catalog: connection errors
#    - checkout: cascading failures from product-catalog
#    - frontend: product pages fail
#    - Low CPU (proves it's not overload)

# 4. Wait for completion, then run table lock (10 minutes)
./postgres-chaos-scenarios.sh table-lock

# 5. Show in Honeycomb:
#    - accounting: order table queries blocked
#    - product-catalog: products table queries blocked
#    - Query duration spikes (30+ seconds)
#    - No connection errors
#    - Low CPU (proves queries are waiting, not executing)
#    - checkout: fails due to product-catalog timeout

# 6. Finally run slow query (5 minutes)
echo "y" | ./postgres-chaos-scenarios.sh slow-query &

# 7. Show in Honeycomb:
#    - CPU saturation (80-100%)
#    - accounting: All queries 10-100x slower
#    - product-catalog: All queries 10-40x slower
#    - checkout: Slower end-to-end (both dependencies slow)
#    - No errors, just performance degradation across the board
```

---

## Honeycomb Dashboard Recommendations

### Dashboard: Database Health & Multi-Service Impact

**Row 1: PostgreSQL Resource Metrics**

- CPU utilization (system.cpu.utilization)
- Memory usage (system.memory.usage)
- Connection count (db.connection.count / db.connection.max)
- Disk I/O operations

**Row 2: Service Query Performance**

- accounting: P95 query duration by statement
- product-catalog: P95 query duration by statement
- Side-by-side comparison to spot symmetric vs asymmetric impact

**Row 3: Error Patterns**

- accounting: Error count by exception type
- product-catalog: Error count by exception type
- Connection errors vs timeout errors

**Row 4: Downstream Impact**

- checkout: P95 duration for product-catalog calls
- checkout: P95 duration for order placement
- frontend: Error rate

---

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
   IF(CONTAINS($exception.message, "could not connect"), "connection_exhaustion",
      IF(GT($duration_ms, 30000), "possible_lock",
         IF(GT($duration_ms, 1000), "slow_query", "other"))))
```

**Service Impact Type:**

```
# For identifying which chaos scenario is active
IF(EQUALS($service.name, "accounting") AND EQUALS($service.name, "product-catalog"),
   "symmetric_impact",  # Both services affected
   "asymmetric_impact") # One service affected more than other
```

---

## Post-Scenario Analysis

After running each scenario, analyze:

1. **Time to detection:** How long until metrics showed the problem in each service?
2. **Symptom clarity:** Could you distinguish the root cause?
3. **Blast radius:** Which services were directly vs indirectly affected?
4. **Service dependency mapping:** Did you see the accounting → checkout → frontend chain?
5. **Service dependency mapping:** Did you see the product-catalog → checkout → frontend chain?
6. **Recovery time:** How long for each service to return to normal?

---

## Best Practices

1. **Run scenarios separately** - Don't overlap tests
2. **Monitor before starting** - Establish baseline metrics for ALL services
3. **Wait between tests** - Allow full recovery (~5 minutes)
4. **Check pod status** - Ensure PostgreSQL pod is healthy
5. **Monitor multiple services** - Watch accounting, product-catalog, checkout, frontend
6. **Clean up after** - Run `./postgres-chaos-scenarios.sh clean` when done
7. **Document observations** - Note which services were affected and how

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

# Check which services are connected
kubectl exec -n otel-demo <POD> -- psql -U root otel -c \
  "SELECT application_name, count(*) FROM pg_stat_activity GROUP BY application_name;"
```

### Table Lock Doesn't Block

```bash
# Verify locks are active
kubectl exec -n otel-demo <POD> -- psql -U root otel -c \
  "SELECT * FROM pg_locks WHERE relation IN ('order'::regclass, 'products'::regclass);"

# Check waiting queries
kubectl exec -n otel-demo <POD> -- psql -U root otel -c \
  "SELECT pid, wait_event_type, query FROM pg_stat_activity WHERE wait_event_type = 'Lock';"
```

### Slow Query Not Slow Enough

```bash
# Increase table size for more expensive queries
./postgres-chaos-scenarios.sh clean
kubectl exec -n otel-demo <POD> -- pgbench -i -s 200 -U root otel
./postgres-chaos-scenarios.sh slow-query
```

### Product-Catalog Not Showing Impact

```bash
# Verify product-catalog is using the database
kubectl logs -n otel-demo -l app.kubernetes.io/component=product-catalog --tail=50

# Check if products table exists
kubectl exec -n otel-demo <POD> -- psql -U root otel -c \
  "SELECT count(*) FROM products;"

# Generate load on product-catalog to see database queries
# Browse products or run load generator
```

---

## Summary

| Scenario              | Command                                            | Duration | Primary Impact                                  | Secondary Impact   |
| --------------------- | -------------------------------------------------- | -------- | ----------------------------------------------- | ------------------ |
| Connection exhaustion | `./postgres-chaos-scenarios.sh connection-exhaust` | 5 min    | accounting + product-catalog                    | checkout, frontend |
| Table lock            | `./postgres-chaos-scenarios.sh table-lock`         | 10 min   | accounting (order) + product-catalog (products) | checkout, frontend |
| Slow query            | `./postgres-chaos-scenarios.sh slow-query`         | 5 min    | ALL database consumers equally                  | checkout (slower)  |

---

## Key Learnings

1. **Multiple consumers magnify blast radius** - PostgreSQL issues affect both accounting AND product-catalog, causing cascading failures in checkout and frontend.

2. **Symmetric vs Asymmetric failures:**

   - Connection exhaustion & CPU saturation = symmetric (all services affected equally)
   - Table locks = asymmetric (only services using locked tables affected)

3. **Cascading failure chains:**

   - accounting blocked → Kafka backlog → checkout slow → frontend errors
   - product-catalog blocked → checkout can't get products → frontend broken

4. **Observability requirements:**
   - Must monitor ALL database consumers, not just one
   - Track service dependencies (who calls who)
   - Correlate metrics across services to see full blast radius

**These scenarios help you build muscle memory for diagnosing database issues in production and understanding multi-service impact patterns!** 🔍🗃️🔥
