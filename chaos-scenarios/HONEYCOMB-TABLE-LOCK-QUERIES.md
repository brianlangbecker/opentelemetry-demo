# Honeycomb Queries for Table Lock Test

**Purpose:** Exact queries to run in Honeycomb to see table lock impact.

---

## 🔍 **Quick Diagnostic: Is Anything Happening?**

### Query 1: Check if Accounting Service Has Any Database Queries

```
WHERE service.name = "accounting"
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 10 minutes
```

**What to look for:**
- **COUNT > 0** = Service is active
- **COUNT = 0** = Service not receiving requests (no traffic)

---

### Query 2: Check if Product-Catalog Has Any Database Queries

```
WHERE service.name = "product-catalog"
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 10 minutes
```

**What to look for:**
- **COUNT > 0** = Service is active
- **COUNT = 0** = Service not receiving requests (no traffic)

---

## 📊 **Table Lock Impact Queries**

### Query 3: Accounting Database Query Duration (Primary)

```
WHERE service.name = "accounting"
  AND db.system = "postgresql"
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **P99 > 30,000ms** = Queries timing out (blocked by lock)
- **MAX > 30,000ms** = Some queries hitting timeout
- **If all < 1000ms:** No queries hitting locked table yet

**Alternative (if db.system doesn't exist):**
```
WHERE service.name = "accounting"
  AND db.statement EXISTS
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

---

### Query 4: Product-Catalog Database Query Duration

```
WHERE service.name = "product-catalog"
  AND db.system = "postgresql"
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **P99 > 30,000ms** = Product queries timing out
- **MAX > 30,000ms** = Queries hitting timeout

---

### Query 5: Count Slow Queries (>10 seconds)

```
WHERE service.name IN ("accounting", "product-catalog")
  AND duration_ms > 10000
VISUALIZE COUNT
GROUP BY service.name, time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **COUNT > 0** = Queries taking >10 seconds (likely blocked)
- **Increasing count** = More queries hitting the lock

---

### Query 6: Timeout Errors (>30 seconds)

```
WHERE service.name IN ("accounting", "product-catalog")
  AND duration_ms > 30000
VISUALIZE COUNT
GROUP BY service.name, time(1m)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **COUNT > 0** = Queries timing out (30+ seconds)
- These are the "errors" from table locks

---

### Query 7: All Database Queries (See What's Happening)

```
WHERE service.name IN ("accounting", "product-catalog")
  AND db.statement EXISTS
VISUALIZE COUNT, P95(duration_ms), MAX(duration_ms)
BREAKDOWN db.statement
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
LIMIT 20
```

**What to look for:**
- Which queries are running
- Which queries are slow
- Are queries hitting `order` or `products` tables?

---

## 🔍 **If You See Nothing: Troubleshooting**

### Step 1: Check if Services Are Active

```
WHERE service.name IN ("accounting", "product-catalog", "checkout")
VISUALIZE COUNT
GROUP BY service.name, time(1m)
TIME RANGE: Last 10 minutes
```

**Expected:** Should see activity for all services

**If COUNT = 0:**
- Services not receiving requests
- **Fix:** Generate traffic (place orders, browse products)

---

### Step 2: Check if Database Queries Exist

```
WHERE db.statement EXISTS
VISUALIZE COUNT
BREAKDOWN service.name
GROUP BY time(1m)
TIME RANGE: Last 10 minutes
```

**Expected:** Should see database queries from accounting and product-catalog

**If COUNT = 0:**
- No database queries being made
- Services might be using different database
- **Fix:** Check service configuration

---

### Step 3: Check if Queries Hit Locked Tables

```
WHERE db.statement EXISTS
VISUALIZE COUNT
BREAKDOWN db.statement
GROUP BY time(1m)
TIME RANGE: Last 10 minutes
LIMIT 30
```

**What to look for:**
- Queries containing `"order"` or `products`
- Are these queries actually running?

---

### Step 4: Check All Fields Available

```
WHERE service.name = "accounting"
VISUALIZE COUNT
BREAKDOWN *
LIMIT 100
```

**What to do:**
- Look for fields starting with `db.`
- Note which fields exist:
  - `db.system`?
  - `db.statement`?
  - `db.name`?
  - `db.operation`?

---

## 🎯 **Simplified Queries (If Fields Don't Match)**

### If `db.system` doesn't exist:

```
WHERE service.name = "accounting"
  AND (db.statement EXISTS OR db.name EXISTS)
VISUALIZE P95(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

### If `db.statement` doesn't exist:

```
WHERE service.name = "accounting"
VISUALIZE P95(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Then filter manually:**
- Look for spans with high duration
- Check if they're database-related

---

## 📋 **Step-by-Step: Find Table Lock Impact**

### Step 1: Verify Services Are Active

```
WHERE service.name IN ("accounting", "product-catalog")
VISUALIZE COUNT
GROUP BY service.name, time(1m)
TIME RANGE: Last 10 minutes
```

**If COUNT = 0:** Generate traffic first!

### Step 2: Find Database Spans

```
WHERE service.name = "accounting"
VISUALIZE COUNT
BREAKDOWN *
LIMIT 50
```

**Look for:**
- Fields containing "db"
- Fields containing "sql"
- Fields containing "database"

### Step 3: Check Duration of Database Spans

```
WHERE service.name = "accounting"
  AND <database_field> EXISTS
VISUALIZE P95(duration_ms), MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Replace `<database_field>` with actual field name from Step 2**

### Step 4: Look for Slow Queries

```
WHERE service.name = "accounting"
  AND <database_field> EXISTS
  AND duration_ms > 10000
VISUALIZE COUNT, MAX(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

---

## 🔧 **Common Field Names**

**Database-related fields might be:**
- `db.system` - Database system (postgresql, mysql, etc.)
- `db.statement` - SQL statement
- `db.name` - Database name
- `db.operation` - Operation type (SELECT, INSERT, etc.)
- `db.sql.table` - Table name
- `db.postgresql.table` - PostgreSQL-specific table name

**Try these queries:**
```
WHERE db.system = "postgresql"
WHERE db.statement EXISTS
WHERE db.name EXISTS
WHERE db.operation EXISTS
```

---

## 🚨 **If Still Nothing: Generate Traffic**

**The locks are active, but you need traffic hitting them:**

1. **Place an order:**
   - Go to frontend
   - Add items to cart
   - Complete checkout
   - This triggers accounting service to write to `order` table

2. **Browse products:**
   - Go to frontend
   - View product pages
   - This triggers product-catalog to read from `products` table

3. **Use Locust:**
   - Start load generator
   - Set users = 10-25
   - Enable checkout flow
   - This generates continuous traffic

**After generating traffic:**
- Wait 30+ seconds
- Check queries again
- Should see duration climbing toward 30,000ms

---

## ✅ **Quick Checklist**

- [ ] Locks active in PostgreSQL? (Check with `pg_locks`)
- [ ] Services running? (Check pod status)
- [ ] Traffic hitting services? (Check service logs)
- [ ] Database queries happening? (Check Honeycomb for `db.*` fields)
- [ ] Queries hitting locked tables? (Check `db.statement` for "order" or "products")
- [ ] Duration > 30,000ms? (Wait 30+ seconds for timeouts)

---

**Last Updated:** December 2024  
**Status:** Honeycomb query reference

