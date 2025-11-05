# PostgreSQL Load Testing Strategy

This document outlines the recommended approach for database load testing in the OpenTelemetry Demo.

---

## Overview

We use **two complementary tools** for PostgreSQL testing:

1. **postgres-seed/** - Database initialization and seeding
2. **pgbench.sh** - High-performance load testing

---

## 1. Database Seeding

**Location:** `infra/postgres-seed/`

**Purpose:** Initialize the database with realistic test data

**Files:**
- `seed-simple.sql` - Minimal dataset for basic testing
- `seed-150k.sql` - Large dataset (150,000 orders) for realistic load
- `complete-seed.sql` - Full schema and comprehensive data

**Usage:**
```bash
cd infra/postgres-seed/

# Get PostgreSQL pod
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

# Seed with 150k orders
kubectl exec -n otel-demo $POD -- psql -U root otel < seed-150k.sql
```

---

## 2. Load Testing with pgbench

**Location:** `infra/pgbench/pgbench.sh`

**Purpose:** Generate high transaction volume to stress-test the database

**Why pgbench over SQL chaos scripts?**

| Metric | SQL Chaos Scripts | pgbench |
|--------|------------------|---------|
| **TPS** | 10-50 | 3,000-50,000 |
| **Speed** | Slow (single connection) | Fast (connection pooling) |
| **Realism** | Chaos patterns | Industry-standard TPC-B |
| **Observability** | Good | Excellent |
| **Simplicity** | Complex | Simple |

---

## Quick Start

```bash
cd infra/

# 1. Seed the database (one-time)
cd postgres-seed/
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n otel-demo $POD -- psql -U root otel < seed-150k.sql
cd ..

# 2. Run load test
cd pgbench/
./pgbench.sh light    # Quick 30-second test
./pgbench.sh normal   # 5-10 minute stress test
./pgbench.sh beast    # 30+ minute extreme load (may crash pod)
```

---

## Load Testing Scenarios

### Development Testing
```bash
cd infra/pgbench/
# Quick verification that everything works
./pgbench.sh light
```

### Demo Preparation
```bash
cd infra/pgbench/
# Moderate load that shows metrics without crashing
echo "y" | ./pgbench.sh normal &

# Open Honeycomb and watch:
# - CPU climbing to 60-80%
# - Transaction rate at 10,000-20,000 TPS
# - P95 latency increasing to 10-50ms
```

### Chaos Engineering
```bash
cd infra/pgbench/
# Extreme load designed to trigger failures
echo "y" | ./pgbench.sh beast

# Expected outcomes:
# - CPU at 100%
# - Memory exhaustion
# - OOMKilled event
# - Pod restart
# - Service recovery observable in Honeycomb
```

---

## Observability in Honeycomb

### Metrics to Track

**System Metrics:**
```
Dataset: Metrics
WHERE service.name = "postgresql"
Calculate: AVG(system.cpu.utilization), AVG(system.memory.usage)
```

**Kubernetes Events:**
```
Dataset: k8s-events
WHERE k8s.pod.name contains "postgresql"
  AND (k8s.container.last_terminated.reason = "OOMKilled"
       OR k8s.event.reason = "BackOff")
```

**Application Impact:**
```
Dataset: frontend, cart, checkout
WHERE db.system = "postgresql"
Calculate: P95(duration_ms), COUNT
GROUP BY service.name
```

---

## Migration from SQL Chaos Scripts

**What changed:**
- ❌ **Removed:** `postgres-chaos/` directory (beast-mode-chaos.sql, etc.)
- ✅ **Kept:** `postgres-seed/` directory (database initialization)
- ✅ **Added:** `pgbench.sh` (high-performance load testing)

**Why?**
- pgbench is **100-1000x faster** (3,000+ TPS vs 10-50 TPS)
- **Industry standard** PostgreSQL benchmarking tool
- **Simpler** - no complex SQL scripts, runs inside the pod
- **Better observability** - generates consistent, predictable metrics

---

## Best Practices

### 1. Always Seed First
```bash
# Seed database before running load tests
cd postgres-seed/
kubectl exec -n otel-demo $POD -- psql -U root otel < seed-150k.sql
```

### 2. Start Small
```bash
cd infra/pgbench/
# Verify everything works before running beast mode
./pgbench.sh light
```

### 3. Monitor Resource Usage
```bash
# Watch pod resource consumption during tests
kubectl top pod -n otel-demo -l app.kubernetes.io/component=postgresql --watch
```

### 4. Check Table Status
```bash
cd infra/pgbench/
# Verify pgbench tables are initialized
./pgbench.sh status
```

### 5. Clean Up After Testing
```bash
cd infra/pgbench/
# Remove pgbench tables when done
./pgbench.sh clean
```

---

## Troubleshooting

### "Table does not exist" Error
```bash
cd infra/pgbench/
# Initialize pgbench tables
./pgbench.sh init
```

### Low Transaction Rate
```bash
# Check if pod is resource-constrained
kubectl describe pod -n otel-demo -l app.kubernetes.io/component=postgresql

# Increase resources in otel-demo-values.yaml
postgresql:
  resources:
    limits:
      memory: "2Gi"
      cpu: "4000m"
```

### Pod Keeps Crashing
```bash
# This is expected during beast mode!
# Check termination reason:
kubectl get pod -n otel-demo -l app.kubernetes.io/component=postgresql \
    -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'

# Look for OOMKilled in Honeycomb k8s-events dataset
```

---

## Documentation

- **pgbench details:** See `PGBENCH-README.md`
- **Seed scripts:** See `postgres-seed/README.md`

---

## Summary

| Task | Tool | Command |
|------|------|---------|
| Initialize DB | postgres-seed | `kubectl exec ... psql < seed-150k.sql` |
| Quick test | pgbench | `./pgbench.sh light` |
| Demo load | pgbench | `./pgbench.sh normal` |
| Chaos test | pgbench | `./pgbench.sh beast` |
| Check status | pgbench | `./pgbench.sh status` |
| Cleanup | pgbench | `./pgbench.sh clean` |

---

**Ready to test?** Start with `cd infra/pgbench/ && ./pgbench.sh light` and work your way up! 🚀
