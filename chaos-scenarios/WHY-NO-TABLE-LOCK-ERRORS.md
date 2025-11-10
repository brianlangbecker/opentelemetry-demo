# Why No Errors During Table Lock Test?

**Problem:** Table lock test is running, locks are active, but not seeing errors in Honeycomb.

---

## ✅ **Current Status: Locks ARE Active**

**What I found:**
- ✅ **Locks active:** AccessExclusiveLock on `order` and `products` tables (PID 2598)
- ✅ **Queries waiting:** 3 queries blocked waiting for locks (PIDs 36, 800, 2644)
- ✅ **Lock process running:** Background process holding locks for 10 minutes

**The locks are working!** The issue is **how errors manifest**.

---

## 🔍 **Key Insight: Table Locks Cause Timeouts, Not Immediate Errors**

### What Actually Happens

1. **Query arrives** → Tries to access locked table
2. **Query blocks** → Waits for lock (doesn't error immediately)
3. **Query times out** → After 30+ seconds, returns timeout error
4. **Error appears** → Only after timeout period

**Result:** You see **high query duration** (30,000+ ms) before errors appear.

---

## 📊 **What to Look For in Honeycomb**

### ❌ **Don't Look For:**
- Immediate error spikes
- Connection errors
- High error counts right away

### ✅ **Look For:**
- **Query duration > 30,000ms** (30+ seconds)
- **P99 latency spikes** (not error counts)
- **Timeout errors** (after 30+ seconds)

---

## 🔍 **Honeycomb Queries to Run**

### Query 1: Accounting Query Duration (Primary)

```
WHERE service.name = "accounting"
  AND db.system = "postgresql"
  AND db.statement CONTAINS "order"
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **P99 > 30,000ms** (30+ seconds) = queries timing out
- **MAX > 30,000ms** = some queries hitting timeout
- **Gradual increase** = queries blocking and waiting

**If you see < 1000ms:** Queries aren't hitting the locked table yet (need more traffic)

---

### Query 2: Product-Catalog Query Duration

```
WHERE service.name = "product-catalog"
  AND db.system = "postgresql"
  AND db.statement CONTAINS "products"
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **P99 > 30,000ms** = product queries timing out
- **MAX > 30,000ms** = queries hitting timeout

---

### Query 3: Count of Slow Queries (>10 seconds)

```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.system = "postgresql"
  AND duration_ms > 10000
VISUALIZE COUNT
GROUP BY service.name, time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **COUNT > 0** = queries taking >10 seconds (blocked)
- **Increasing count** = more queries hitting the lock

---

### Query 4: Timeout Errors (After 30+ seconds)

```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.system = "postgresql"
  AND duration_ms > 30000
VISUALIZE COUNT
GROUP BY service.name, time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **COUNT > 0** = queries timing out (30+ seconds)
- These are the "errors" you're looking for

---

### Query 5: Checkout Service Impact

```
WHERE service.name = "checkout"
  AND rpc.service = "oteldemo.ProductCatalogService"
VISUALIZE P95(duration_ms), COUNT
GROUP BY http.status_code, time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **High P95 duration** = product lookups timing out
- **Error status codes** = 500, 504 (timeout errors)

---

## 🚨 **Why You Might Not See Errors**

### Issue 1: No Traffic Hitting Locked Tables

**Symptoms:**
- Locks active, but no queries waiting
- Query duration stays normal (<1000ms)

**Diagnosis:**
```bash
# Check if services are making requests
kubectl logs -n otel-demo -l app.kubernetes.io/name=accounting --tail=50 | grep -i "order\|insert"
kubectl logs -n otel-demo -l app.kubernetes.io/name=product-catalog --tail=50 | grep -i "product\|select"
```

**Fix:**
- Generate traffic: Place orders, browse products
- Use Locust: Start load generator with checkout flow
- Wait for traffic to hit locked tables

---

### Issue 2: Queries Not Timing Out Yet

**Symptoms:**
- Queries blocking (waiting for lock)
- But duration < 30,000ms (haven't timed out yet)

**Diagnosis:**
```
WHERE service.name = "accounting"
  AND db.system = "postgresql"
  AND duration_ms BETWEEN 10000 AND 30000
VISUALIZE COUNT
```

**Fix:**
- Wait longer (queries need 30+ seconds to timeout)
- Check P99 duration (should be climbing toward 30s)

---

### Issue 3: Wrong Time Range in Query

**Symptoms:**
- Locks active now, but query shows old data

**Fix:**
- Set **TIME RANGE: Last 15 minutes** (or current time window)
- Ensure query includes the lock period

---

### Issue 4: Services Using Different Tables

**Symptoms:**
- Locks on `order` and `products`
- But services querying different tables

**Diagnosis:**
```
WHERE service.name = "accounting"
  AND db.system = "postgresql"
VISUALIZE COUNT
BREAKDOWN db.statement
```

**Check:** Are queries actually hitting `order` and `products` tables?

---

## 🔧 **Verify Locks Are Blocking Queries**

### Check Active Locks

```bash
POD=$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -c "
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

**Expected:** Should see `AccessExclusiveLock` with `granted = t`

### Check Waiting Queries

```bash
kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -c "
  SELECT pid, wait_event_type, wait_event, state, LEFT(query, 80) as query
  FROM pg_stat_activity 
  WHERE wait_event_type = 'Lock';
"
```

**Expected:** Should see queries with `wait_event_type = 'Lock'` (blocked)

**If no waiting queries:**
- No traffic hitting locked tables
- Generate traffic (place orders, browse products)

---

## 📈 **Expected Timeline**

**With locks active and traffic:**

| Time | What Happens | What You See |
|------|--------------|--------------|
| 0s | Lock acquired | Locks active in PostgreSQL |
| 5s | First query hits lock | Query blocks (waiting) |
| 10s | More queries block | P99 duration climbing |
| 20s | Queries still waiting | P99 > 20,000ms |
| 30s | **First timeout** | **Error appears** (duration > 30,000ms) |
| 60s | Multiple timeouts | Error count increasing |

**Key Point:** Errors appear **after 30+ seconds**, not immediately!

---

## 🎯 **Quick Diagnostic**

### Step 1: Verify Locks Active

```bash
POD=$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -c "
  SELECT COUNT(*) as active_locks
  FROM pg_locks
  WHERE locktype = 'relation' 
    AND relation IN ('order'::regclass, 'products'::regclass)
    AND mode = 'AccessExclusiveLock'
    AND granted = true;
"
```

**Expected:** Should return `2` (one for order, one for products)

### Step 2: Check Waiting Queries

```bash
kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -c "
  SELECT COUNT(*) as waiting_queries
  FROM pg_stat_activity 
  WHERE wait_event_type = 'Lock';
"
```

**Expected:** Should be > 0 if traffic is hitting locked tables

### Step 3: Generate Traffic

**If waiting_queries = 0:**
- No traffic hitting locked tables
- **Generate traffic:**
  - Place orders (triggers accounting writes to `order` table)
  - Browse products (triggers product-catalog reads from `products` table)
  - Use Locust with checkout flow

### Step 4: Check Query Duration in Honeycomb

```
WHERE service.name = "accounting"
  AND db.system = "postgresql"
  AND db.statement CONTAINS "order"
VISUALIZE MAX(duration_ms)
GROUP BY time(30s)
TIME RANGE: Last 10 minutes
```

**Expected:**
- Duration should climb toward 30,000ms
- After 30+ seconds, should see timeout errors

---

## 🔍 **What Errors Look Like**

### In Honeycomb Traces

**Normal query:**
- `duration_ms: 50ms`
- `otel.status_code: OK`

**Blocked query (before timeout):**
- `duration_ms: 15,000ms` (still waiting)
- `otel.status_code: OK` (not errored yet)

**Timeout error (after 30s):**
- `duration_ms: 30,000ms+`
- `otel.status_code: ERROR`
- `error.message: "query timeout"` or similar

---

## 🚨 **Alert Configuration**

**Query:**
```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.system = "postgresql"
  AND duration_ms > 30000
VISUALIZE COUNT
GROUP BY service.name, time(1m)
```

**Alert Conditions:**
- **Trigger:** `COUNT > 5` queries/minute
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL

**Message:**
```
🔴 Table Lock Detected

Service: {{service.name}}
Blocked Queries: {{COUNT}} queries timing out (>30s)
Duration: >30 seconds

Action: Check PostgreSQL locks and identify blocking query
```

---

## ✅ **Summary**

**The locks ARE working!** You're just looking for the wrong thing:

1. **Don't look for:** Immediate error spikes
2. **Look for:** Query duration > 30,000ms (timeouts)
3. **Timeline:** Errors appear after 30+ seconds, not immediately
4. **Need traffic:** Generate orders/products requests to hit locked tables
5. **Check P99/MAX duration:** Not just error counts

**Next Steps:**
1. Generate traffic (place orders, browse products)
2. Wait 30+ seconds for timeouts
3. Check `duration_ms > 30000` in Honeycomb
4. Look at P99/MAX duration, not just error counts

---

**Last Updated:** December 2024  
**Status:** Diagnostic guide

