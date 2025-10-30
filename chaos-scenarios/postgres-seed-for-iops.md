# PostgreSQL Database Pre-Seeding for IOPS Demo

**Optional Setup**: This is NOT required for the standard Helm installation. Use this to pre-populate the database with 150,000 orders (~148 MB) to immediately demonstrate IOPS pressure without waiting hours for organic growth.

---

## 📋 **Prerequisites**

- OpenTelemetry Demo installed via Helm
- `kubectl` access to the cluster
- 5-10 minutes for setup

**Note:** If you installed using `infra/otel-demo-values.yaml` or `infra/otel-demo-values-aws.yaml`, PostgreSQL memory is already set to 300Mi. Skip to Step 1.

---

## 🎯 **Why Seed the Database?**

**Without Seeding:**

- Start with empty database (10 MB)
- Wait 2-4 hours for organic growth to 150+ MB
- Cache hit ratio stays at 99%+ until database exceeds cache size

**With Seeding:**

- Start with 150,000 orders (148 MB)
- Database exceeds PostgreSQL shared_buffers (64 MB)
- **Immediate IOPS pressure** with cache hit ratio at ~85-90%

---

## ⚙️ **Step 1: Create Persistent Volume and Configure PostgreSQL Memory**

This ensures seeded data persists across PostgreSQL restarts.

### **Option A: Create PVC Manually**

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

### **Option B: Use Pre-configured File (Recommended)**

```bash
kubectl apply -f infra/postgres-pvc.yaml
```

**This file includes:**

- PVC for persistent storage (2Gi)
- ConfigMap with PostgreSQL tuning parameters

---

## ⚙️ **Step 2: Attach PVC to PostgreSQL**

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

**Wait for PostgreSQL to restart:**

```bash
kubectl get pods -n otel-demo -l app.kubernetes.io/name=postgresql -w
```

---

## 💾 **Step 3: Create Seed Script**

Save this to `seed-150k.sql`:

```sql
-- Seed 150,000 orders (~148 MB) for IOPS demo
INSERT INTO "order" (order_id)
SELECT gen_random_uuid()::TEXT
FROM generate_series(1, 150000);

-- Add 3 items per order (~366k items)
INSERT INTO orderitem (
    item_cost_currency_code,
    item_cost_units,
    item_cost_nanos,
    product_id,
    quantity,
    order_id
)
SELECT
    'USD',
    floor(random() * 100 + 10)::BIGINT,
    floor(random() * 1000000000)::INT,
    (ARRAY['OLJCESPC7Z','66VCHSJNUP','1YMWWN1N4O','L9ECAV7KIM','2ZYFJ3GM2N'])[floor(random() * 5 + 1)::INTEGER],
    floor(random() * 5 + 1)::INT,
    o.order_id
FROM "order" o
CROSS JOIN generate_series(1, 3)
ON CONFLICT DO NOTHING;

-- Add shipping for each order
INSERT INTO shipping (
    shipping_tracking_id,
    shipping_cost_currency_code,
    shipping_cost_units,
    shipping_cost_nanos,
    street_address,
    city,
    state,
    country,
    zip_code,
    order_id
)
SELECT
    gen_random_uuid()::TEXT,
    'USD',
    floor(random() * 20 + 5)::BIGINT,
    floor(random() * 1000000000)::INT,
    floor(random() * 9999 + 1)::TEXT || ' Main St',
    (ARRAY['New York','Los Angeles','Chicago','Houston','Phoenix'])[floor(random() * 5 + 1)::INTEGER],
    (ARRAY['NY','CA','IL','TX','AZ'])[floor(random() * 5 + 1)::INTEGER],
    'USA',
    lpad(floor(random() * 99999)::TEXT, 5, '0'),
    o.order_id
FROM "order" o;

SELECT COUNT(*) as total_orders, pg_size_pretty(pg_database_size('otel')) as db_size FROM "order";
```

---

## 🚀 **Step 4: Execute Seed Script**

### **4a. Set PostgreSQL Memory to 300Mi (Required)**

**⚠️ CRITICAL:** PostgreSQL needs 300Mi memory to:

- Handle the bulk insert of 150K orders + 450K items + 150K shipments
- Run stably with the resulting 200+ MB database
- Avoid crashes and corruption

```bash
kubectl set resources deployment/postgresql -n otel-demo \
  --limits=memory=300Mi \
  --requests=memory=300Mi
```

**Wait for restart:**

```bash
sleep 30
kubectl get pods -n otel-demo -l app.kubernetes.io/name=postgresql
```

**Note:** 300Mi is **permanent** - DO NOT reduce it after seeding or the database will crash.

### **4b. Copy and Execute Seed Script**

```bash
# Copy seed script to PostgreSQL pod
kubectl cp seed-150k.sql otel-demo/$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}'):/tmp/seed.sql

# Execute seed (takes 3-5 minutes)
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -f /tmp/seed.sql
```

**Expected Output:**

```
INSERT 0 150000
INSERT 0 366289
INSERT 0 150000
 total_orders | db_size
--------------+---------
       150000 | 148 MB
(1 row)
```

---

## ⚙️ **Step 5: Verify IOPS Configuration**

**PostgreSQL is already configured for IOPS pressure:**

**Current Setup:**

- PostgreSQL Memory: **300Mi** (required to run)
- PostgreSQL shared_buffers: **128 MB** (default cache)
- Database Size: **~200 MB** (after seeding)
- **200 MB > 128 MB = IOPS pressure!** 🎯

**Why This Works:**

- Database (200 MB) exceeds cache (128 MB) by **1.56x**
- PostgreSQL must read from disk when cache is full
- Result: Visible IOPS pressure with 85-90% cache hit ratio

**⚠️ DO NOT reduce memory below 300Mi** - the database will crash!

---

## ✅ **Step 6: Verify Setup**

### **Check Data Persisted:**

```bash
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -c "SELECT COUNT(*) as orders, pg_size_pretty(pg_database_size('otel')) as db_size FROM \"order\";"
```

**Expected:**

```
 orders | db_size
--------+---------
 150000 | 148 MB
```

### **Check Cache Hit Ratio (After Load Starts):**

```bash
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -c "SELECT datname, blks_read, blks_hit, round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_ratio FROM pg_stat_database WHERE datname='otel';"
```

**With 200 users active, expect:**

- **Before seeding:** 99.5%+ cache hit ratio (everything fits in cache)
- **After seeding:** 85-90% cache hit ratio (IOPS pressure!) 🎯

---

## 📊 **Query Cache Hit Ratio in Honeycomb**

### **Create Calculated Field:**

**Name:** `cache_hit_ratio`

**Formula:**

```
DIV(
  MUL($postgresql.blks_hit, 100),
  ADD($postgresql.blks_hit, $postgresql.blks_read)
)
```

### **Query:**

```
DATASET: opentelemetry-demo
WHERE: postgresql.blks_hit EXISTS
VISUALIZE: AVG(cache_hit_ratio) AS "Cache Hit %"
GROUP BY: time(5m)
TIME RANGE: Last 1 hour
```

**Expected Results:**

- **85-90%**: IOPS pressure visible ✅
- **95%+**: Database mostly cached (increase orders or reduce shared_buffers)
- **<80%**: Heavy IOPS pressure (good for demos!)

---

## 🔄 **Start Load Generator**

Now start traffic to demonstrate IOPS impact:

```bash
kubectl set env deployment/load-generator -n otel-demo \
  LOCUST_USERS=200 \
  LOCUST_SPAWN_RATE=10
```

**Monitor in Honeycomb:**

- Cache hit ratio dropping under load
- Disk reads increasing (`SUM(RATE($postgresql.blks_read))`)
- Query latency increasing

---

## 🧹 **Cleanup (Optional)**

### **Remove Seed Data:**

```bash
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -c "TRUNCATE TABLE \"order\" CASCADE;"
```

### **Remove PVC:**

```bash
kubectl delete pvc postgresql-data -n otel-demo
```

---

## 📝 **Summary**

| **Setting**              | **Value** | **Purpose**                                     |
| ------------------------ | --------- | ----------------------------------------------- |
| Orders                   | 150,000   | Sufficient data to exceed cache                 |
| Order Items              | ~367,000  | 3 items per order (bulk of database size)       |
| Database Size            | ~200+ MB  | Exceeds 128 MB shared_buffers (1.56x)           |
| PostgreSQL Memory        | 300 Mi    | **Required minimum** - DO NOT reduce            |
| shared_buffers           | 128 MB    | Default PostgreSQL cache size                   |
| PVC Size                 | 2 Gi      | Persistent storage for seed data                |
| Seeding Time             | 3-5 min   | Using bulk inserts                              |
| Expected Cache Hit Ratio | 85-90%    | Visible IOPS pressure under load                |
| IOPS Pressure Ratio      | 1.56x     | Database size / shared_buffers (200MB / 128MB ) |

**This setup demonstrates IOPS pressure immediately without waiting hours for organic database growth!** 🚀
