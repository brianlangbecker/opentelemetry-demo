# OpenTelemetry Demo - Infrastructure Setup

This directory contains Helm values and Kubernetes resources for deploying the OpenTelemetry Demo.

---

## 📁 **Files Overview**

| **File**                         | **Purpose**                               | **When to Use**                          |
| -------------------------------- | ----------------------------------------- | ---------------------------------------- |
| `otel-demo-values.yaml`          | Main Helm values (Honeycomb config)       | ✅ Every install                         |
| `otel-demo-values-aws.yaml`      | AWS-specific Helm values                  | AWS deployments                          |
| `helm-commands.sh`               | Common Helm commands (install, dry-run)   | Quick reference for Helm operations      |
| `postgres-persistent-setup.yaml` | PVC + ConfigMap for PostgreSQL            | For IOPS demos with persistence          |
| `postgres-patch.yaml`            | Patch to attach PVC to PostgreSQL         | After Helm install (if using PVC)        |
| `install-with-persistence.sh`    | **One-command installer**                 | 🚀 **Easiest way** to enable persistence |
| `seed-150k.sql`                  | Pre-seed 150K orders into DB              | Optional: instant IOPS demo              |
| `run-postgres-chaos.sh`          | 🎭 **Interactive chaos script**           | Create locks, slow queries, bloat        |
| `postgres-chaos-queries.sql`     | Manual chaos SQL scenarios                | Advanced users, custom chaos tests       |
| `heavy-maintenance-chaos.md`     | 🔥 5-10 min chaos guide                   | Long-form demos, detailed walkthrough    |
| `verify-postgres.md`             | PostgreSQL verification & troubleshooting | When setting up or debugging PostgreSQL  |

---

## 🚀 **Quick Start**

### **Option 1: Standard Install (Ephemeral PostgreSQL)**

```bash
# PostgreSQL data will be lost on pod restart
helm install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml \
  --create-namespace
```

### **Option 2: Install with Persistent PostgreSQL (Recommended for IOPS Demos)**

```bash
# One command - sets up PVC and patches PostgreSQL automatically
./install-with-persistence.sh otel-demo-values.yaml
```

**What it does:**

1. ✅ Creates namespace
2. ✅ Creates 2Gi PersistentVolumeClaim
3. ✅ Installs Helm chart
4. ✅ Patches PostgreSQL to use persistent storage

### **Option 3: Manual Install with Persistence**

```bash
# Step 1: Create namespace and PVC
kubectl create namespace otel-demo
kubectl apply -f postgres-persistent-setup.yaml

# Step 2: Install Helm chart
helm install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml

# Step 3: Patch PostgreSQL deployment
kubectl patch deployment postgresql -n otel-demo \
  --patch-file postgres-patch.yaml
```

---

## 💾 **Pre-Seeding PostgreSQL Database (Optional)**

For instant IOPS pressure without waiting hours for organic growth:

### **Quick Seed (150K orders ~200MB)**

```bash
# 1. Copy seed script to PostgreSQL pod
kubectl cp seed-150k.sql otel-demo/$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}'):/tmp/

# 2. Execute seed script (takes 5-10 minutes)
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -f /tmp/seed-150k.sql

# 3. Verify database size
kubectl exec -n otel-demo $(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U root -d otel -c "SELECT pg_size_pretty(pg_database_size('otel'));"
```

**Expected Result:** Database grows to ~200+ MB immediately, showing cache pressure without waiting.

**⚠️ Important:**

- Requires PostgreSQL memory set to **300Mi** (already configured in values files)
- Use with persistent storage (PVC) to avoid re-seeding after restarts
- See **[postgres-seed-for-iops.md](../chaos-scenarios/postgres-seed-for-iops.md)** for complete guide

---

## 🎭 **Database Chaos Engineering (Optional)**

Create locks, slow queries, and performance issues for observability demos:

### **Interactive Chaos Script (Recommended)**

```bash
# Run interactive menu for chaos scenarios
./run-postgres-chaos.sh
```

**Available Scenarios:**

| **Scenario**             | **Effect**                                 | **Observable Metrics**                         | **Duration**  |
| ------------------------ | ------------------------------------------ | ---------------------------------------------- | ------------- |
| 🔒 Table Lock            | Blocks all writes to `order` table         | `pg_stat_activity.wait_event`, blocked queries | 30 seconds    |
| 🔐 Row Locks             | Creates contention on 100 random orders    | Row lock waits, transaction queue depth        | 20 seconds    |
| 🐌 Slow Query            | Full table scan + expensive joins          | Query duration, CPU usage, disk I/O            | ~10 seconds   |
| 💥 Bloat Generator       | Creates 10K dead tuples                    | `n_dead_tup`, table bloat percentage           | ~30 seconds   |
| 📊 Long Analytics        | Heavy aggregation across all tables        | Memory usage, temp file creation               | ~15 seconds   |
| 🔥 **Heavy Maintenance** | **Sustained locks + bloat + slow queries** | **All metrics, continuous pressure**           | **5-10 mins** |

**Monitoring Commands:**

- **Show Active Locks:** See what's currently locked
- **Show Blocked Queries:** Identify lock contention
- **Show Table Bloat:** Dead tuple percentage per table
- **Show Slow Queries:** Queries running >5 seconds
- **VACUUM FULL:** Clean up dead tuples and reclaim space

### **Manual Chaos Queries**

For advanced users, see `postgres-chaos-queries.sql` for individual SQL chaos scenarios.

**Example Usage:**

```bash
# Copy chaos script to PostgreSQL pod
kubectl cp postgres-chaos-queries.sql otel-demo/$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}'):/tmp/

# Run specific scenario manually
kubectl exec -n otel-demo <postgres-pod> -- \
  psql -U root -d otel -c "BEGIN; LOCK TABLE \"order\" IN EXCLUSIVE MODE; SELECT pg_sleep(30); COMMIT;"
```

**What to Observe in Honeycomb:**

```
DATASET: opentelemetry-demo
WHERE: postgresql.* EXISTS

# Lock wait time
VISUALIZE: MAX(postgresql.rows_dead_ratio)
GROUP BY: table

# Transaction age (old transactions = locks)
VISUALIZE: MAX(postgresql.connection.max_age)

# Dead tuple accumulation (from bloat scenario)
VISUALIZE: SUM(INCREASE(postgresql.tup_updated)), SUM(INCREASE(postgresql.tup_deleted))
GROUP BY: time(1m)
```

---

## ❓ **Why is the PVC Not in `otel-demo-values.yaml`?**

**Short Answer:** The OpenTelemetry Demo Helm chart doesn't support PVC configuration for PostgreSQL through `values.yaml`.

**Detailed Explanation:**

- The demo is designed for **ephemeral testing**, not production persistence
- The `postgresql` component in the Helm chart only exposes:
  - `env` (environment variables) ✅
  - `resources` (CPU/memory limits) ✅
  - `replicas`, `service.port` ✅
  - ❌ **No** `volumes`, `volumeMounts`, or `persistence` options

**Solution:**

- PVCs must be created as **separate Kubernetes resources**
- Then **patched** onto the PostgreSQL deployment after Helm install
- Use our `install-with-persistence.sh` script for automated setup

---

## 🔄 **Common Operations**

### **Upgrade Helm Release**

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml
```

### **Uninstall (Keeps PVC if created separately)**

```bash
helm uninstall otel-demo -n otel-demo

# To also delete PVC and data
kubectl delete pvc postgresql-data -n otel-demo
```

### **Port Forwarding**

```bash
# Frontend
kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080

# Jaeger UI
kubectl -n otel-demo port-forward svc/jaeger-query 16686:16686

# Load Generator (Locust)
kubectl -n otel-demo port-forward svc/load-generator 8089:8089
```

---

## 🎭 **For Chaos Demos**

See documentation in the chaos-scenarios directory:

- **[postgres-chaos-iops-demo.md](../chaos-scenarios/postgres-chaos-iops-demo.md)** - Cache pressure chaos demo
- **[postgres-disk-iops-pressure.md](../chaos-scenarios/postgres-disk-iops-pressure.md)** - Organic IOPS growth
- **[postgres-seed-for-iops.md](../chaos-scenarios/postgres-seed-for-iops.md)** - Database pre-seeding

---

## 📚 **Additional Resources**

- [SETUP-NOTES.md](SETUP-NOTES.md) - Comprehensive setup guide
- [ChaosTesting.md](../ChaosTesting.md) - All chaos scenarios
- [chaos-scenarios/](../chaos-scenarios/) - Individual scenario guides
