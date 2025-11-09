# PostgreSQL Table Lock - Quick Guide

**Purpose:** Demonstrate how table locks block database operations and create cascading service failures.

---

## 🎯 **What It Does**

Locks the `order` and `products` tables with **ACCESS EXCLUSIVE** locks for **10 minutes**, blocking:
- ✅ **accounting service** - Cannot write to `order` table
- ✅ **product-catalog service** - Cannot read from `products` table
- ✅ **checkout service** - Cascading failures from both services
- ✅ **frontend** - User-visible errors

**Result:** Services that need these tables are blocked, causing timeouts and failures.

---

## ⚙️ **How to Run**

```bash
cd infra/postgres-chaos
./postgres-chaos-scenarios.sh table-lock
```

**Duration:** 10 minutes (600 seconds)

**What happens:**
1. Acquires exclusive locks on `order` and `products` tables
2. Holds locks for 10 minutes
3. All queries on these tables block and timeout
4. Services fail with timeouts (not connection errors)

---

## 📊 **What to See in Honeycomb**

### Primary Query: Accounting Blocked Queries

```
WHERE service.name = "accounting"
  AND db.system = "postgresql"
  AND db.statement CONTAINS "order"
VISUALIZE P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:** P99 > 30,000ms (30+ seconds) - queries timing out

---

### Product-Catalog Blocked Queries

```
WHERE service.name = "product-catalog"
  AND db.system = "postgresql"
  AND db.statement CONTAINS "products"
VISUALIZE P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
```

**Expected:** P99 > 30,000ms (30+ seconds) - queries timing out

---

### Compare Both Services

```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.system = "postgresql"
  AND duration_ms > 10000
VISUALIZE COUNT
GROUP BY service.name, time(1m)
```

**Expected:** Both services show blocked queries during lock period

---

### Checkout Service Impact

```
WHERE service.name = "checkout"
  AND rpc.service = "oteldemo.ProductCatalogService"
VISUALIZE P95(duration_ms), COUNT
GROUP BY http.status_code, time(1m)
```

**Expected:** High latency and timeout errors (product-catalog blocked)

---

### Frontend Errors

```
WHERE service.name = "frontend"
  AND http.status_code >= 500
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** Error rate increases (product pages fail to load)

---

## 🔍 **Key Indicators**

**What you'll see:**
- ✅ Query duration: 30,000+ ms (timeouts)
- ✅ No connection errors (connections work, queries block)
- ✅ Low CPU (<30%) - queries waiting, not executing
- ✅ Both services affected: accounting (order) + product-catalog (products)

**What you won't see:**
- ❌ Connection errors ("too many clients")
- ❌ High CPU (queries are blocked, not running)
- ❌ All queries slow (only queries on locked tables)

---

## 🚨 **Alert Setup**

**Query:**
```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.system = "postgresql"
  AND duration_ms > 30000
VISUALIZE COUNT
GROUP BY time(1m)
```

**Alert Conditions:**
- **Trigger:** COUNT > 5 queries/minute
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL

**Message:**
```
🔴 Table Lock Detected

Services: accounting, product-catalog
Blocked Queries: {{COUNT}} queries timing out
Duration: >30 seconds

Action: Check PostgreSQL locks and identify blocking query
```

---

## 🎓 **Understanding the Blast Radius**

```
Table Lock (order + products)
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

**Key Point:** Different services affected based on which table they need.

---

## 🔧 **Verify Locks Are Active**

**Check locks in PostgreSQL:**
```bash
kubectl exec -n otel-demo <POD> -c postgresql -- psql -U root otel -c "
  SELECT
    locktype,
    relation::regclass as table_name,
    mode,
    granted
  FROM pg_locks
  WHERE locktype = 'relation' 
    AND relation IN ('order'::regclass, 'products'::regclass);
"
```

**Check waiting queries:**
```bash
kubectl exec -n otel-demo <POD> -c postgresql -- psql -U root otel -c "
  SELECT pid, wait_event_type, query 
  FROM pg_stat_activity 
  WHERE wait_event_type = 'Lock';
"
```

---

## 📋 **Comparison: Table Lock vs Other Scenarios**

| Symptom | Table Lock | Connection Exhaustion | Slow Query |
|---------|------------|----------------------|------------|
| **Connection errors** | ❌ No | ✅ Yes | ❌ No |
| **Query timeouts** | ✅ Yes (30s+) | ✅ Yes | ⚠️ Rare |
| **High CPU** | ❌ No | ❌ No | ✅ Yes |
| **Affects specific tables** | ✅ Yes | ❌ No | ❌ No |
| **accounting impact** | 🔥 Severe | 🔥 Severe | ⚠️ Moderate |
| **product-catalog impact** | 🔥 Severe | 🔥 Severe | ⚠️ Moderate |

---

## ✅ **Quick Checklist**

- [ ] Run: `./postgres-chaos-scenarios.sh table-lock`
- [ ] Honeycomb shows: accounting queries >30s
- [ ] Honeycomb shows: product-catalog queries >30s
- [ ] No connection errors (different from connection exhaustion)
- [ ] Low CPU (queries blocked, not executing)
- [ ] Frontend shows errors (product pages fail)
- [ ] Alert configured: Triggers on >30s queries

---

**Last Updated:** November 9, 2025  
**Duration:** 10 minutes  
**Tables Locked:** `order`, `products`  
**Impact:** accounting (writes), product-catalog (reads), checkout, frontend

