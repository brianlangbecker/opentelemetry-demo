# OpenTelemetry Demo Setup Notes

## 📦 **Files Configured for IOPS Demo**

### **1. Helm Values Files**

Both Helm values files have been updated with PostgreSQL memory settings:

#### `infra/otel-demo-values.yaml`

```yaml
components:
  postgresql:
    resources:
      limits:
        memory: 300Mi
      requests:
        memory: 300Mi
```

#### `infra/otel-demo-values-aws.yaml`

```yaml
components:
  postgresql:
    resources:
      limits:
        memory: 300Mi
      requests:
        memory: 300Mi
```

**Why 300Mi?**

- Supports 200+ MB database after seeding
- Prevents OOM crashes and corruption
- Still creates IOPS pressure (shared_buffers = 128 MB)

---

### **2. PostgreSQL PVC Configuration**

#### `infra/postgres-pvc.yaml`

```yaml
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
```

**Purpose:**

- Persistent storage for seeded data
- Data survives PostgreSQL restarts
- Required for IOPS demo

---

### **3. Seed Scripts**

#### `infra/seed-simple.sql`

- Inserts 150,000 orders
- Adds 3 orderitems per order (~450K items)
- Adds shipping info for each order
- **Result:** ~200 MB database

#### `infra/complete-seed.sql`

- Adds orderitems and shipping to existing orders
- Used to complete partial seeds
- Idempotent (uses ON CONFLICT DO NOTHING)

---

### **4. PostgreSQL Deployment Patch**

#### `infra/postgres-patch.yaml`

```yaml
spec:
  template:
    spec:
      containers:
        - name: postgresql
          resources:
            limits:
              memory: 300Mi
            requests:
              memory: 300Mi
          volumeMounts:
            - name: postgresql-data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: postgresql-data
          persistentVolumeClaim:
            claimName: postgresql-data
```

**Usage:**

```bash
kubectl patch deployment postgresql -n otel-demo \
  --patch-file infra/postgres-patch.yaml
```

---

## 🚀 **Quick Start with Pre-configured Files**

### **Option 1: Install with Helm (PostgreSQL memory already set)**

```bash
helm install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values infra/otel-demo-values.yaml \
  --create-namespace
```

**PostgreSQL will automatically have 300Mi memory.**

---

### **Option 2: Add IOPS Demo Seeding (After Helm Install)**

```bash
# 1. Create PVC
kubectl apply -f infra/postgres-pvc.yaml

# 2. Attach PVC to PostgreSQL
kubectl patch deployment postgresql -n otel-demo \
  --patch-file infra/postgres-patch.yaml

# 3. Wait for restart
kubectl rollout status deployment/postgresql -n otel-demo

# 4. Seed database
kubectl cp infra/seed-simple.sql otel-demo/$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}'):/tmp/seed.sql

kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -f /tmp/seed.sql

# 5. Verify
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -c "SELECT COUNT(*) as orders, pg_size_pretty(pg_database_size('otel')) as db_size FROM \"order\";"
```

**Expected:**

```
 orders | db_size
--------+---------
 150000 | ~200 MB
```

---

## ⚠️ **Critical Settings**

### **DO NOT CHANGE:**

1. **PostgreSQL Memory:** Must stay at **300Mi minimum**

   - Reducing below 300Mi will cause crashes
   - Database is ~200+ MB after seeding
   - Corruption occurs with insufficient memory

2. **PVC:** Must be attached for data persistence

   - Without PVC, data is lost on restart
   - Must re-seed after every restart without PVC

3. **shared_buffers:** Default 128 MB is correct
   - Provides IOPS pressure with 200 MB database
   - DO NOT increase (defeats IOPS demo purpose)

---

## 🎯 **Current Configuration Status**

| **Component**     | **Setting**           | **Status**              |
| ----------------- | --------------------- | ----------------------- |
| PostgreSQL Memory | 300Mi                 | ✅ Set in Helm values   |
| PVC               | postgresql-data (2Gi) | ✅ Created and attached |
| Database          | 150K orders, ~200 MB  | ✅ Seeded               |
| shared_buffers    | 128 MB                | ✅ Default (correct)    |
| IOPS Ratio        | 1.56x (200MB / 128MB) | ✅ Optimal              |

---

## 📊 **Expected Results**

**With 200 users generating traffic:**

- **Cache Hit Ratio:** 85-90% (visible IOPS pressure)
- **Disk Reads:** Increasing as cache fills
- **Database Size:** ~200 MB (stable with seed data)
- **PostgreSQL Memory Usage:** ~250-280 MB (safe with 300Mi limit)

**Query in Honeycomb:**

```
DATASET: opentelemetry-demo
WHERE: postgresql.blks_hit EXISTS

# Create calculated field:
cache_hit_ratio = DIV(MUL($postgresql.blks_hit, 100), ADD($postgresql.blks_hit, $postgresql.blks_read))

VISUALIZE: AVG(cache_hit_ratio) AS "Cache Hit %"
GROUP BY: time(5m)
```

---

## 🔧 **Troubleshooting**

### **PostgreSQL Crashing (CrashLoopBackOff)**

**Symptom:** Pod shows Error or CrashLoopBackOff

**Cause:** Memory too low for database size

**Fix:**

```bash
kubectl set resources deployment/postgresql -n otel-demo \
  --limits=memory=300Mi --requests=memory=300Mi
```

### **Database Corruption**

**Symptom:** `index "XXX_pkey" contains unexpected zero page` errors

**Cause:** Unclean shutdowns from OOM or repeated restarts

**Fix:**

```bash
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -c "REINDEX DATABASE otel;"
```

### **Data Lost After Restart**

**Symptom:** Order count resets to 0

**Cause:** PVC not attached

**Fix:** Follow Step 2 in Quick Start to attach PVC

---

## 📚 **Documentation References**

- **IOPS Demo Setup:** `postgres-seed-for-iops.md`
- **IOPS Scenario Guide:** `postgres-disk-iops-pressure.md`
- **Helm Values:** `infra/otel-demo-values.yaml`
- **PVC Config:** `infra/postgres-pvc.yaml`
- **Seed Scripts:** `infra/seed-simple.sql`, `infra/complete-seed.sql`
