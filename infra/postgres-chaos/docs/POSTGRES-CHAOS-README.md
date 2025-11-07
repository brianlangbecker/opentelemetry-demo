# PostgreSQL Chaos Testing & Load Generation

Comprehensive PostgreSQL chaos testing and load generation using `pgbench` - PostgreSQL's built-in benchmarking tool. Runs **directly inside the PostgreSQL pod** for maximum performance and simplicity.

## Why pgbench?

- ✅ **Much faster** than SQL scripts - connection pooling and parallelism
- ✅ **Industry standard** - PostgreSQL's official benchmarking tool
- ✅ **Configurable** - easy to adjust load levels
- ✅ **Realistic** - simulates real transactional workload (TPC-B)
- ✅ **Observable** - generates tons of metrics for Honeycomb dashboards
- ✅ **Simple** - runs inside the PostgreSQL pod, no network issues

---

## Quick Start

```bash
cd infra/postgres-chaos/

# Light load - quick test (30 seconds)
./postgres-chaos-scenarios.sh light

# Normal load - moderate stress (5-10 minutes)
./postgres-chaos-scenarios.sh normal

# BEAST MODE - maximum stress (30+ minutes)
./postgres-chaos-scenarios.sh beast

# Initialize tables manually
./postgres-chaos-scenarios.sh init

# Check table status
./postgres-chaos-scenarios.sh status

# Clean up tables
./postgres-chaos-scenarios.sh clean
```

---

## Load Levels

### ⚡ **Light** (Quick Test)

```
Duration: ~30 seconds
Clients: 10
Transactions: 10,000 total
TPS: ~3,000-5,000
Use case: Quick verification that load testing works
```

### 🔥 **Normal** (Moderate Load)

```
Duration: ~5-10 minutes
Clients: 50
Transactions: 500,000 total
TPS: ~10,000-20,000
Use case: Standard load testing, observe latency under pressure
```

### 💀 **Beast** (Maximum Load)

```
Duration: ~30+ minutes
Clients: 100
Transactions: 5,000,000 total
TPS: ~20,000-50,000+
Use case: Stress testing, trigger OOMKills, observe failure modes
Resource impact: EXTREME - will likely cause pod restarts/crashes
```

---

## Real Results from Test Run

```
Transaction type: TPC-B (sort of)
Clients: 10
Transactions: 10,000
TPS: 3,197
Failures: 0 (0.000%)
Latency avg: 3.086 ms
Statement latencies:
  - UPDATE accounts: 0.144 ms
  - SELECT account:   0.087 ms
  - UPDATE tellers:   0.237 ms
  - UPDATE branches:  0.975 ms
  - INSERT history:   0.079 ms
  - COMMIT:           1.488 ms
```

---

## What pgbench Does

pgbench creates standard TPC-B benchmark tables:

| Table            | Scale 10 | Scale 100  | Scale 200  |
| ---------------- | -------- | ---------- | ---------- |
| pgbench_accounts | 1M rows  | 10M rows   | 20M rows   |
| pgbench_branches | 10 rows  | 100 rows   | 200 rows   |
| pgbench_tellers  | 100 rows | 1,000 rows | 2,000 rows |
| pgbench_history  | growing  | growing    | growing    |

**Transaction Simulation (per txn):**

```sql
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers SET tbalance = tbalance + :delta WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (...);
END;
```

---

## Observing in Honeycomb

Once pgbench is running, check Honeycomb for:

### **Metrics Dataset**

```
WHERE service.name = "postgresql"
GROUP BY k8s.pod.name
Calculate: AVG(system.cpu.utilization), AVG(system.memory.usage)
```

### **k8s-events Dataset**

```
WHERE k8s.pod.name contains "postgresql"
  AND (k8s.container.last_terminated.reason = "OOMKilled"
       OR k8s.event.reason = "BackOff"
       OR k8s.event.reason = "Killing")
```

### **PostgreSQL Logs** (if instrumented)

```
WHERE service.name = "postgresql"
GROUP BY severity_text
Calculate: COUNT
```

---

## Expected Metrics During Load

| Metric           | Light       | Normal        | Beast          |
| ---------------- | ----------- | ------------- | -------------- |
| TPS              | 3,000-5,000 | 10,000-20,000 | 20,000-50,000+ |
| CPU Usage        | 20-40%      | 60-80%        | 90-100%        |
| Memory           | Stable      | Growing       | OOMKill risk   |
| Latency (P95)    | <10ms       | 10-50ms       | 50-500ms+      |
| Connection count | 10          | 50            | 100            |
| Disk I/O         | Low         | Medium        | Very High      |

---

## Advanced Usage

### Run with Custom Parameters

```bash
# Get PostgreSQL pod
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

# Custom load: 25 clients, 5000 transactions each
kubectl exec -n otel-demo $POD -- pgbench \
    -c 25 \
    -j 12 \
    -t 5000 \
    -P 5 \
    -r \
    -U root \
    otel

# Read-only test (no writes)
kubectl exec -n otel-demo $POD -- pgbench \
    -c 20 \
    -t 10000 \
    -S \
    -U root \
    otel

# Custom SQL script
cat > custom-test.sql <<EOF
\set aid random(1, 100000)
SELECT * FROM pgbench_accounts WHERE aid = :aid;
EOF

kubectl exec -n otel-demo $POD -- pgbench \
    -c 50 \
    -t 10000 \
    -f /tmp/custom-test.sql \
    -U root \
    otel
```

### Background Execution

```bash
# Run in background (pod will continue even if you disconnect)
kubectl exec -n otel-demo $POD -- bash -c "pgbench -c 100 -t 50000 -P 30 -U root otel &"

# Check if still running
kubectl exec -n otel-demo $POD -- ps aux | grep pgbench
```

---

## Monitoring Active Tests

```bash
# Watch PostgreSQL pod stats
kubectl top pod -n otel-demo -l app.kubernetes.io/component=postgresql --watch

# Watch connection count
kubectl exec -n otel-demo $POD -- psql -U root otel -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"

# Watch transaction rate
kubectl exec -n otel-demo $POD -- psql -U root otel -c "SELECT xact_commit, xact_rollback FROM pg_stat_database WHERE datname = 'otel';"

# Watch table sizes
kubectl exec -n otel-demo $POD -- psql -U root otel -c "SELECT pg_size_pretty(pg_total_relation_size('pgbench_accounts'));"
```

---

## Troubleshooting

### Test Fails Immediately

```bash
# Check if tables exist
./postgres-chaos-scenarios.sh status

# Initialize tables manually
./postgres-chaos-scenarios.sh init
```

### PostgreSQL Crashes During Test

**This is expected during Beast Mode!** Check:

```bash
# Watch for pod restarts
kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -w

# Check termination reason
kubectl get pod -n otel-demo -l app.kubernetes.io/component=postgresql \
    -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'

# View recent events
kubectl get events -n otel-demo --sort-by='.lastTimestamp' | grep postgresql
```

### Performance Lower Than Expected

**CPU throttling:**

```bash
# Check resource limits
kubectl get pod -n otel-demo -l app.kubernetes.io/component=postgresql \
    -o jsonpath='{.items[0].spec.containers[0].resources}'
```

**Increase resources** in `otel-demo-values.yaml`:

```yaml
postgresql:
  resources:
    limits:
      memory: '2Gi' # Increase for better caching
      cpu: '4000m' # Increase for more TPS
    requests:
      memory: '1Gi'
      cpu: '2000m'
```

---

## Comparison: pgbench vs SQL Chaos Scripts

| Feature          | SQL Scripts | pgbench           |
| ---------------- | ----------- | ----------------- |
| Speed            | 10-50 TPS   | 3,000-50,000 TPS  |
| Transactions     | Thousands   | Millions          |
| Duration         | 30+ minutes | 5-30 minutes      |
| Resource usage   | Medium      | Very High         |
| Type of load     | Bloat/locks | Transactional     |
| Observability    | Good        | Excellent         |
| Crash likelihood | Low         | High (Beast mode) |

**Use SQL scripts for:** Bloat testing, vacuum testing, long-running query analysis
**Use pgbench for:** High TPS load, connection stress, crash testing, realistic workload

---

## Cleanup

```bash
# Stop any running pgbench processes
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n otel-demo $POD -- pkill pgbench

# Drop pgbench tables
./postgres-chaos-scenarios.sh clean
```

---

## Demo Script

Perfect for showing database observability in real-time:

```bash
# 1. Open Honeycomb dashboard (PostgreSQL metrics)

# 2. Start load in background
echo "y" | ./postgres-chaos-scenarios.sh normal &

# 3. Watch metrics climb in Honeycomb
#    - CPU usage increasing
#    - Transaction rate spiking
#    - Latency growing

# 4. For chaos demo, run Beast mode
echo "y" | ./postgres-chaos-scenarios.sh beast

# 5. Watch PostgreSQL pod crash and restart
kubectl get pods -n otel-demo -w

# 6. Show recovery in Honeycomb
#    - OOMKilled event
#    - Pod restart
#    - Service recovery
```

---

## Next Steps

1. ✅ **Verified working** with light load (10k txns, 3,197 TPS)
2. Try normal load and observe Honeycomb dashboards
3. Build PostgreSQL performance dashboard in Honeycomb
4. When ready, unleash Beast Mode and watch the chaos
5. Use for demos to show real-time database observability

**Pro tip:** Run `./postgres-chaos-scenarios.sh normal` during demos to show realistic database performance metrics without crashing the system!
