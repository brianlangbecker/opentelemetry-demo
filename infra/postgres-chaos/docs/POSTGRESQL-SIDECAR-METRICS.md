# PostgreSQL Sidecar OTel Collector - Comprehensive Metrics Guide

**Purpose:** Document all PostgreSQL and filesystem metrics collected by the sidecar OTel Collector  
**Audience:** SREs, Platform Engineers, Observability Team  
**Created:** November 8, 2025

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ PostgreSQL Pod (StatefulSet)                                │
│                                                              │
│  ┌─────────────────────┐      ┌──────────────────────────┐ │
│  │ PostgreSQL          │      │ OTel Collector (Sidecar) │ │
│  │ Container           │      │                          │ │
│  │                     │      │ Receivers:               │ │
│  │ localhost:5432 ─────┼──────┤ • postgresql (localhost) │ │
│  │                     │      │ • hostmetrics (pod-local)│ │
│  │ Volumes:            │      │                          │ │
│  │ • PVC (persistent)  │      │ Exporters:               │ │
│  │ • emptyDir (ephem.) │      │ • otlp → otelcol:4317    │ │
│  └─────────────────────┘      └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │ Main OTel Collector   │
                              │ (Cluster-level)       │
                              │                       │
                              │ → Honeycomb/Prometheus│
                              └───────────────────────┘
```

---

## Filesystem Metrics - Volume Segregation

### ✅ YES - Metrics ARE Segregated by Volume

Each volume mount gets **separate metrics** identified by attributes:

```json
{
  "metric": "system.filesystem.usage",
  "attributes": {
    "device": "/dev/nvme1n1",
    "mountpoint": "/var/lib/postgresql/data",
    "type": "ext4",
    "state": "used"
  },
  "value": 1717986918  // bytes (1.6 GB)
}

{
  "metric": "system.filesystem.usage",
  "attributes": {
    "device": "/dev/nvme1n1",
    "mountpoint": "/var/lib/postgresql/data",
    "type": "ext4",
    "state": "free"
  },
  "value": 429496730  // bytes (400 MB)
}
```

### Honeycomb Query Examples

**1. Total Disk Size per Volume:**

```
WHERE service.name = "postgresql-sidecar"
  AND system.filesystem.usage EXISTS
GROUP BY mountpoint
VISUALIZE SUM(system.filesystem.usage)
```

**2. Disk Usage Percentage:**

```
WHERE service.name = "postgresql-sidecar"
  AND system.filesystem.utilization EXISTS
GROUP BY mountpoint
VISUALIZE MAX(system.filesystem.utilization)
```

**3. Used vs Free Comparison:**

```
WHERE service.name = "postgresql-sidecar"
  AND system.filesystem.usage EXISTS
GROUP BY mountpoint, state
VISUALIZE SUM(system.filesystem.usage)
```

### Expected Volumes in Output

| Mount Point                | Type                 | Description               | Expected Size |
| -------------------------- | -------------------- | ------------------------- | ------------- |
| `/var/lib/postgresql/data` | Persistent (PVC)     | PostgreSQL data directory | 2 GB          |
| `/tmp`                     | Ephemeral (emptyDir) | Temp files                | Variable      |
| `/var/tmp`                 | Ephemeral (emptyDir) | Temp storage              | Variable      |

---

## Complete PostgreSQL Metrics Catalog

### 🆕 NEW Metrics (Not in Main Collector)

| Metric                              | Description                | Use Case                           |
| ----------------------------------- | -------------------------- | ---------------------------------- |
| `postgresql.connection.max`         | Max connections configured | Compare with `postgresql.backends` |
| `postgresql.wal.age`                | WAL age in bytes           | Replication lag detection          |
| `postgresql.wal.delay`              | WAL delay in time          | Replication health                 |
| `postgresql.index.size`             | Per-index size             | Identify bloated indexes           |
| `postgresql.index.scans`            | Index scan count           | Unused index detection             |
| `postgresql.replication.data_delay` | Replication lag in bytes   | Replica health monitoring          |
| `postgresql.operations`             | Sequential vs index scans  | Query optimization                 |
| `postgresql.rows`                   | Per-table row operations   | Table activity monitoring          |
| `postgresql.blocks_read`            | Per-table block reads      | Table-level I/O analysis           |

### 📊 Existing Metrics (Also in Main Collector - Now with Better Accuracy)

| Metric                     | Sidecar Advantage                                | Main Collector Limitation        |
| -------------------------- | ------------------------------------------------ | -------------------------------- |
| `postgresql.db_size`       | **Queries both `otel` AND `postgres` databases** | Only queries `postgres` database |
| `postgresql.blks_hit/read` | **Per-database breakdown**                       | Aggregated only                  |
| `postgresql.backends`      | **Pod-local, no network latency**                | Network hop to PostgreSQL        |
| `postgresql.table.size`    | **All tables in `otel` database**                | Limited visibility               |

---

## Strategy: Managing Duplicate Metrics

### Option 1: Disable PostgreSQL Receiver in Main Collector (RECOMMENDED)

**Why:** Sidecar provides more accurate, comprehensive metrics.

**In `src/otel-collector/otelcol-config.yml`:**

```yaml
receivers:
  # postgresql:  # ← DISABLE - now handled by sidecar
  #   endpoint: ${POSTGRES_HOST}:${POSTGRES_PORT}
  #   username: root
  #   password: ${POSTGRES_PASSWORD}
  #   ...

service:
  pipelines:
    metrics:
      receivers:
        [
          docker_stats,
          httpcheck/frontend-proxy,
          hostmetrics,
          nginx,
          otlp,
          redis,
          spanmetrics
        ]
      # ↑ Notice: removed 'postgresql' from list
```

**In `kubernetes/opentelemetry-demo.yaml`:**

```yaml
receivers:
  # postgresql:  # ← DISABLE
  #   endpoint: postgresql:5432
  #   ...

service:
  pipelines:
    metrics:
      receivers:
        [
          httpcheck/frontend-proxy,
          jaeger,
          nginx,
          otlp,
          prometheus,
          redis,
          zipkin,
          spanmetrics
        ]
      # ↑ Remove 'postgresql'
```

### Option 2: Keep Both - Filter in Honeycomb

**Why:** Compare cluster-level vs pod-level metrics for validation.

**Honeycomb Filters:**

```
# Pod-local metrics (sidecar)
WHERE service.name = "postgresql-sidecar"

# Cluster-level metrics (main collector)
WHERE service.name != "postgresql-sidecar"
  AND postgresql.db_size EXISTS
```

### Option 3: Hybrid Approach

**Keep in Main Collector:** Basic health metrics only

- `postgresql.backends`
- `postgresql.deadlocks`

**Keep in Sidecar:** Everything else (disk, tables, indexes, WAL)

---

## Key Metrics for Chaos Testing

### Connection Exhaustion Tests

```
postgresql.backends          # Current connections
postgresql.connection.max    # Max allowed (should be 100)
```

**Alert when:** `backends / connection.max > 0.90` (90% capacity)

### IOPS Pressure Tests

```
postgresql.blks_hit         # Cache hits
postgresql.blks_read        # Disk reads
postgresql.operations       # Sequential vs index scans
system.disk.operations      # Actual disk ops per second
```

**Cache hit ratio:** `blks_hit / (blks_hit + blks_read) * 100`  
**Alert when:** Cache hit ratio < 90% (indicates I/O pressure)

### Disk Space Tests

```
system.filesystem.usage           # Actual disk usage
system.filesystem.utilization     # Percentage full
postgresql.db_size               # Logical database size
postgresql.table.size            # Per-table sizes
```

**Alert when:** `filesystem.utilization > 85%`

### Table-Level Analysis

```
postgresql.table.size            # Identify large tables
postgresql.index.size            # Identify bloated indexes
postgresql.index.scans           # Unused indexes (scans = 0)
postgresql.tup_fetched          # Query efficiency
postgresql.tup_returned         # Rows scanned vs returned
```

**Query efficiency:** `tup_fetched / tup_returned * 100`  
**Alert when:** < 10% (full table scans, missing indexes)

---

## Deployment Instructions

### 1. Apply ConfigMap

```bash
kubectl apply -f infra/postgres-otel-configmap.yaml
```

### 2. Patch PostgreSQL StatefulSet

```bash
kubectl patch statefulset postgresql -n otel-demo \
  --patch-file infra/postgres-otel-sidecar-patch.yaml
```

### 3. Verify Sidecar

```bash
# Check both containers are running
kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql \
  -o jsonpath='{.items[0].spec.containers[*].name}'

# Expected output: postgresql otel-collector

# Check sidecar logs
kubectl logs -n otel-demo -l app.kubernetes.io/name=postgresql \
  -c otel-collector --tail=100
```

### 4. Verify Metrics in Honeycomb

```
DATASET: opentelemetry-demo
WHERE service.name = "postgresql-sidecar"
  AND postgresql.db_size EXISTS
GROUP BY postgresql.database.name
VISUALIZE MAX(postgresql.db_size)
TIME RANGE: Last 10 minutes
```

**Expected output:**

- `otel` database: ~700 MB (with 1500 products)
- `postgres` database: ~7.3 MB (system DB)

---

## Troubleshooting

### Sidecar Not Starting

```bash
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=postgresql
```

**Common issues:**

- ConfigMap not found: Ensure `postgres-otel-config` exists
- Secret not found: Check `postgresql` secret exists
- Resource limits: Check memory/CPU availability

### No Metrics in Honeycomb

```bash
# Check sidecar debug logs
kubectl logs -n otel-demo -l app.kubernetes.io/name=postgresql \
  -c otel-collector | grep -i error

# Check main collector is receiving
kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector \
  | grep "postgresql-sidecar"
```

### Filesystem Metrics Not Showing

```bash
# Exec into sidecar to check mounts
kubectl exec -n otel-demo -it postgresql-0 -c otel-collector -- df -h

# Should show:
# /var/lib/postgresql/data  (PVC)
# /tmp
# /var/tmp
```

---

## Resource Consumption

**Sidecar OTel Collector:**

- **CPU:** 100m request, 200m limit
- **Memory:** 128 Mi request, 256 Mi limit
- **Network:** ~10 KB/s to main collector
- **Collection Interval:** 30 seconds

**Total Pod Resources (PostgreSQL + Sidecar):**

- **CPU:** ~300m total
- **Memory:** ~384 Mi total

---

## Benefits of Sidecar Approach

✅ **More Accurate Metrics**

- Queries `localhost` (no network latency)
- Sees all databases (`otel` + `postgres`)
- Pod-local filesystem visibility

✅ **Better Granularity**

- Per-database metrics
- Per-table metrics
- Per-index metrics
- Per-volume filesystem metrics

✅ **Chaos Testing Insights**

- Exact disk usage during bloat tests
- Table-level impact visibility
- Connection pool accuracy
- IOPS pressure per table

✅ **Independent Collection**

- Survives main collector restarts
- No shared connection pool with apps
- Isolated troubleshooting

---

## Next Steps

1. **Apply the sidecar** (see Deployment Instructions above)
2. **Run a connection exhaustion test** - Compare `backends` vs `connection.max`
3. **Run an IOPS test** - Monitor cache hit ratio and `system.disk.operations`
4. **Run a disk bloat test** - Track `system.filesystem.usage` and `postgresql.db_size`
5. **Build Honeycomb dashboards** - Use the query examples above

---

## References

- [OTel PostgreSQL Receiver Docs](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/postgresqlreceiver)
- [OTel Host Metrics Receiver Docs](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/hostmetricsreceiver)
- [PostgreSQL System Catalogs](https://www.postgresql.org/docs/current/catalogs.html)
- [Connection Exhaustion Test Results](./CONNECTION-EXHAUSTION-TEST-RESULTS.md)
- [IOPS Blast Radius Test Results](./IOPS-BLAST-RADIUS-TEST-RESULTS.md)
