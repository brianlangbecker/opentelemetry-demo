# Postgres Disk & IOPS Pressure - Database Storage Exhaustion

> ⚠️ **NOTICE: This scenario has not been tested yet.** The commands, queries, and expected outcomes are based on the design and understanding of how the OpenTelemetry Demo works, but have not been validated in practice. Please report any issues or corrections via GitHub issues.

## Overview

This guide demonstrates how to observe **database disk growth and I/O pressure** using the OpenTelemetry Demo's Postgres database and accounting service, with telemetry sent to Honeycomb for analysis.

### Use Case Summary

- **Target Service:** `accounting` (C# microservice) + `postgresql` (Postgres database)
- **Database:** PostgreSQL (stores order transactions)
- **Trigger Mechanism:** Feature flag (`kafkaQueueProblems`) + Load generator
- **Observable Outcome:** Database growth → I/O pressure → Query latency degradation → Disk exhaustion
- **Pattern:** Transactional write pressure (OLTP workload)
- **Monitoring:** Honeycomb UI + Postgres metrics + disk usage commands

---

## Related Scenarios Using `kafkaQueueProblems` Flag

The same feature flag creates different failure modes depending on the target:

| Scenario | Target | Flag Value | Users | Observable Outcome |
|----------|--------|------------|-------|-------------------|
| **[Memory Spike](memory-tracking-spike-crash.md)** | Checkout service (Go) | 2000 | 50 | OOM crash in 60-90s |
| **[Gradual Memory Leak](memory-leak-gradual-checkout.md)** | Checkout service (Go) | 200-300 | 25 | Gradual OOM in 10-20m |
| **[Postgres Disk/IOPS](postgres-disk-iops-pressure.md)** | Postgres database | 2000 | 50 | Disk growth + I/O pressure (this guide) |

**Key Difference:** Memory scenarios crash the checkout service. This scenario fills the Postgres database with transactional data.

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- Docker and Docker Compose installed OR Kubernetes cluster
- Access to Honeycomb UI
- FlagD UI accessible

**⚠️ Before starting, verify Postgres is running and receiving data:**
- See **[verify-postgres.md](verify-postgres.md)** for comprehensive verification queries
- Quick check: `docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"`
- Expected: Should return a row count (may be 0 initially, but proves database is accessible)

---

## How It Works

When `kafkaQueueProblems` flag is enabled:

1. **Checkout service** creates hundreds of Kafka messages per order
2. **Accounting service** consumes ALL messages from Kafka topic
3. **For each message**, accounting service writes to Postgres:
   - 1 Order record (`orders` table)
   - N OrderItem records (`cart_items` table) - one per product
   - 1 Shipping record (`shipping` table)
4. **Database tables grow** with each processed message
5. **I/O pressure builds** from sustained writes
6. **Query latency increases** as tables grow and I/O saturates

**Production Analog:** Simulates RDS/Aurora database under high transaction volume with disk space or IOPS constraints.

---

## Execution Steps

### Step 1: Check Baseline Postgres Status

**For Docker Compose:**

```bash
# Check database size
docker exec postgresql psql -U root -d otelu -c "SELECT pg_size_pretty(pg_database_size('otelu'));"

# Check table sizes
docker exec postgresql psql -U root -d otelu -c "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"

# Check disk usage
docker exec postgresql du -sh /var/lib/postgresql/data
```

**For Kubernetes:**

```bash
# Get postgres pod name
kubectl get pod -n otel-demo | grep postgresql

# Check database size
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT pg_size_pretty(pg_database_size('otelu'));"

# Check table sizes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"

# Check disk usage
kubectl exec -n otel-demo postgresql-0 -- du -sh /var/lib/postgresql/data
```

**Expected baseline:**
```
Database size: ~50MB
orders table: ~8KB
cart_items table: ~8KB
shipping table: ~8KB
```

### Step 2: Enable Feature Flag

1. **Access FlagD UI:**
   ```
   http://localhost:4000
   ```

2. **Configure the flag:**
   - Find `kafkaQueueProblems` in the flag list
   - Click to expand/edit it
   - Set the **"on" variant value** to `2000` (high volume)
   - Set **default variant** to `on`
   - Save changes

**What this does:** Each checkout creates 2000 Kafka messages, all consumed by accounting service and written to Postgres.

### Step 3: Generate Sustained Load

1. **Access Locust Load Generator:**
   ```
   http://localhost:8089
   ```

2. **Configure load test:**
   - Click **"Edit"** button
   - **Number of users:** `50` (sustained load)
   - **Ramp up:** `5` (users per second)
   - **Runtime:** `120m` to `180m` (2-3 hours for significant growth)
   - Click **"Start"**

**Why sustained load:**
- Database growth is cumulative (data persists)
- Need continuous checkouts to accumulate data
- Longer runtime = more observable disk and I/O pressure

### Step 4: Monitor Database Growth in Real-Time

**Watch database size (updates every 60 seconds):**

**For Docker Compose:**

```bash
watch -n 60 'docker exec postgresql psql -U root -d otelu -c "SELECT pg_size_pretty(pg_database_size(\"otelu\"));"'
```

**For Kubernetes:**

```bash
watch -n 60 'kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT pg_size_pretty(pg_database_size(\"otelu\"));"'
```

**Expected growth pattern:**
```
TIME    DATABASE SIZE    STATUS
0m      50MB            Baseline
15m     200MB           Growing
30m     500MB           Steady growth
60m     1.2GB           Significant
90m     2GB             High I/O pressure
120m    3GB             Disk pressure visible
```

**Monitor table growth:**

**For Docker Compose:**

```bash
watch -n 60 'docker exec postgresql psql -U root -d otelu -c "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)), n_live_tup FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"'
```

**For Kubernetes:**

```bash
watch -n 60 'kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)), n_live_tup FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"'
```

**Expected output:**
```
  relname   | pg_size_pretty | n_live_tup
------------+----------------+------------
 cart_items | 1200 MB        |  2500000   (most records - one per product per message)
 orders     |  800 MB        |  1000000   (one per message)
 shipping   |  600 MB        |  1000000   (one per message)
```

**Check I/O statistics:**

**For Docker Compose:**

```bash
docker exec postgresql psql -U root -d otelu -c "SELECT datname, blks_read, blks_hit, blk_read_time, blk_write_time FROM pg_stat_database WHERE datname='otelu';"
```

**For Kubernetes:**

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT datname, blks_read, blks_hit, blk_read_time, blk_write_time FROM pg_stat_database WHERE datname='otelu';"
```

**What to look for:**
- `blks_read` - Disk reads (increases as cache misses grow)
- `blks_hit` - Cache hits (ratio should stay high)
- `blk_read_time` - Time spent reading from disk (increases under I/O pressure)
- `blk_write_time` - Time spent writing to disk (increases with sustained writes)

**Monitor disk I/O wait:**

**For Docker Compose:**

```bash
docker stats postgresql --no-stream
```

**For Kubernetes:**

```bash
kubectl top pod -n otel-demo | grep postgresql
```

---

## Honeycomb Queries for Database Pressure

### Query 1: Order Processing Rate (Write Volume)

```
WHERE service.name = accounting
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**What to look for:**
- High, sustained order processing rate
- Each order = 3+ database writes (orders, cart_items, shipping)
- Directly correlates with database growth

### Query 2: Accounting Service Latency (I/O Pressure Indicator)

```
WHERE service.name = accounting
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**What to look for:**
- Increasing latency as database grows
- P95/P99 spikes indicating I/O wait
- Progressive degradation pattern

**Expected pattern:**
```
TIME    P50     P95     P99     STATUS
0m      20ms    50ms    100ms   Baseline
30m     30ms    80ms    150ms   Growing
60m     50ms    120ms   250ms   I/O pressure
90m     80ms    200ms   400ms   High pressure
120m    120ms   350ms   600ms   Severe degradation
```

### Query 3: Database Connection Metrics

```
WHERE service.name = accounting AND db.system = postgresql
VISUALIZE COUNT
GROUP BY db.operation
TIME RANGE: Last 3 hours
```

**What to look for:**
- INSERT operations dominating (writes)
- Connection pool exhaustion under load

### Query 4: Checkout to Accounting Flow

```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**Cross-reference with accounting service:**
- Checkout creates orders → Kafka → Accounting → Postgres
- Each checkout with `kafkaQueueProblems: 2000` = 2000 Postgres writes

### Query 5: Database Write Latency

```
WHERE service.name = accounting AND db.operation = INSERT
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**What to look for:**
- INSERT latency increasing over time
- Indicates I/O saturation or disk slowdown

### Query 6: Error Rate During Database Pressure

```
WHERE service.name = accounting
VISUALIZE COUNT
GROUP BY otel.status_code
TIME RANGE: Last 3 hours
```

**What to look for:**
- Connection timeout errors
- Database constraint violations
- Lock wait timeouts

### Query 7: Kafka to Database Lag

```
WHERE service.name = accounting
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**What to look for:**
- Growing processing time indicates backlog
- Database becoming bottleneck

### Query 8: Postgres Resource Metrics (if available)

```
WHERE k8s.pod.name STARTS_WITH postgresql
VISUALIZE MAX(k8s.pod.cpu_utilization), MAX(k8s.pod.memory.working_set)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**What to look for:**
- CPU spikes during writes
- Memory growth from cache/buffers

### Query 9: Disk I/O Metrics (if instrumented)

```
WHERE service.name = postgresql OR k8s.pod.name STARTS_WITH postgresql
VISUALIZE MAX(system.disk.io.write_bytes), MAX(system.disk.io.read_bytes)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**What to look for:**
- Sustained high write throughput
- Read I/O increasing as cache effectiveness decreases

### Query 10: End-to-End Checkout Latency

```
WHERE service.name = frontend AND name CONTAINS checkout
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 3 hours
```

**What to look for:**
- User-facing impact of database slowdown
- Checkout latency increases even though accounting is async

---

## Honeycomb Dashboard Configuration

Create a board named **"Postgres Disk & I/O Pressure Analysis"** with these panels:

### Panel 1: Order Processing Volume
```
WHERE service.name = accounting
VISUALIZE COUNT
GROUP BY time(1m)
```

### Panel 2: Accounting Service Latency
```
WHERE service.name = accounting
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

### Panel 3: Database Write Latency
```
WHERE service.name = accounting AND db.operation = INSERT
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

### Panel 4: Database Operations Breakdown
```
WHERE service.name = accounting AND db.system = postgresql
VISUALIZE COUNT
GROUP BY db.operation
```

### Panel 5: Error Rate
```
WHERE service.name = accounting
VISUALIZE COUNT
GROUP BY otel.status_code
```

### Panel 6: Postgres CPU & Memory
```
WHERE k8s.pod.name STARTS_WITH postgresql
VISUALIZE MAX(k8s.pod.cpu_utilization), MAX(k8s.pod.memory.working_set)
GROUP BY time(1m)
```

### Panel 7: Processing Time Heatmap
```
WHERE service.name = accounting
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(1m)
```

### Panel 8: Checkout Success Rate
```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY otel.status_code
```

---

## Advanced Postgres Monitoring

### Check Table Bloat

**For Docker Compose:**

```bash
docker exec postgresql psql -U root -d otelu -c "
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"
```

**For Kubernetes:**

```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"
```

### Check Active Connections

```bash
# Docker Compose
docker exec postgresql psql -U root -d otelu -c "SELECT count(*), state FROM pg_stat_activity WHERE datname='otelu' GROUP BY state;"

# Kubernetes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT count(*), state FROM pg_stat_activity WHERE datname='otelu' GROUP BY state;"
```

### Check Lock Contention

```bash
# Docker Compose
docker exec postgresql psql -U root -d otelu -c "SELECT mode, count(*) FROM pg_locks WHERE database = (SELECT oid FROM pg_database WHERE datname='otelu') GROUP BY mode;"

# Kubernetes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT mode, count(*) FROM pg_locks WHERE database = (SELECT oid FROM pg_database WHERE datname='otelu') GROUP BY mode;"
```

### Check Cache Hit Ratio

```bash
# Docker Compose
docker exec postgresql psql -U root -d otelu -c "
SELECT
  datname,
  round(100.0 * blks_hit / (blks_hit + blks_read), 2) AS cache_hit_ratio
FROM pg_stat_database
WHERE datname='otelu';"

# Kubernetes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "
SELECT
  datname,
  round(100.0 * blks_hit / (blks_hit + blks_read), 2) AS cache_hit_ratio
FROM pg_stat_database
WHERE datname='otelu';"
```

**Expected:**
- Baseline: >99% cache hit ratio
- Under pressure: <95% (more disk I/O)

### Check Row Count Growth

```bash
# Docker Compose
docker exec postgresql psql -U root -d otelu -c "
SELECT
  relname AS table_name,
  n_live_tup AS row_count,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;"

# Kubernetes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "
SELECT
  relname AS table_name,
  n_live_tup AS row_count,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;"
```

---

## Expected Timeline

| Time | Database Size | Row Count (orders) | Cache Hit % | Query Latency | Status |
|------|---------------|-------------------|-------------|---------------|--------|
| 0m | 50MB | 0 | 99.5% | P95: 50ms | Baseline |
| 15m | 200MB | 250k | 99.2% | P95: 80ms | Growing |
| 30m | 500MB | 600k | 98.5% | P95: 120ms | Steady growth |
| 60m | 1.2GB | 1.5M | 97.0% | P95: 200ms | I/O pressure building |
| 90m | 2GB | 2.5M | 95.0% | P95: 350ms | High I/O pressure |
| 120m | 3GB | 3.5M | 92.0% | P95: 500ms | Severe degradation |
| 180m | 4-5GB | 5M+ | <90% | P95: 800ms | Critical |

**Growth rate:** ~1-1.5GB per hour with 50 users and `kafkaQueueProblems: 2000`

---

## Alert Configuration

### Alert 1: Database Size Growth

```
TRIGGER: Database size > 2GB
WHERE: service.name = postgresql
FREQUENCY: Every 5 minutes
ACTION: Warning - database growing rapidly
```

### Alert 2: High Write Latency

```
TRIGGER: P95(duration_ms) > 300
WHERE: service.name = accounting AND db.operation = INSERT
FREQUENCY: Every 1 minute
ACTION: Critical - database write performance degraded
```

### Alert 3: Cache Hit Ratio Drop

```
TRIGGER: Cache hit ratio < 95%
WHERE: db.system = postgresql
FREQUENCY: Every 5 minutes
ACTION: Warning - increased disk I/O
```

### Alert 4: Connection Pool Exhaustion

```
TRIGGER: COUNT(pg_stat_activity) > 80% of max_connections
WHERE: service.name = postgresql
FREQUENCY: Every 1 minute
ACTION: Critical - connection pool near limit
```

### Alert 5: Accounting Service Degradation

```
TRIGGER: P95(duration_ms) > 500
WHERE: service.name = accounting
FREQUENCY: Every 1 minute
ACTION: Warning - order processing slowed (database bottleneck)
```

---

## Trace and Log Correlation

### Finding Database-Impacted Traces

1. **Identify slow accounting operations:**
   ```
   WHERE service.name = accounting AND duration_ms > 500
   VISUALIZE TRACES
   ORDER BY duration_ms DESC
   LIMIT 20
   ```

2. **Click on a slow trace** to see:
   - Full trace from checkout → Kafka → accounting → Postgres
   - Long span duration for database INSERT operations
   - Multiple INSERT operations per order
   - Timestamp correlates with high database load

3. **Correlate with database metrics:**
   - Note the timestamp of slow trace
   - Check table sizes at that time
   - Check cache hit ratio at that time
   - Correlation: Large tables + low cache ratio = slow INSERTs

### Example Correlation Flow

1. User completes checkout at `10:15:23`
2. Checkout service creates 2000 Kafka messages (due to `kafkaQueueProblems: 2000`)
3. Accounting service consumes messages starting at `10:15:23`
4. Each message = 3+ database INSERTs
5. Total: 6000+ INSERTs triggered by single checkout
6. Database has 2GB data, cache hit ratio 94%
7. INSERTs take 300ms each (normally 20ms)
8. Accounting service slow to process messages
9. Visible in Honeycomb as slow accounting service spans

**Honeycomb Trace Query:**
```
WHERE service.name = accounting AND duration_ms > 300
VISUALIZE TRACES
```

Click a trace → See database INSERT spans → Correlate with table size metrics.

---

## Comparison: Postgres vs Other Storage Scenarios

| Aspect | Postgres (OLTP) | OpenSearch (Logs) | Checkout Memory |
|--------|-----------------|-------------------|-----------------|
| **Data Type** | Transactional records | Logs and traces | In-memory objects |
| **Growth Driver** | Order volume | Error rate + traffic | Goroutine leaks |
| **Growth Pattern** | Cumulative, persistent | Cumulative, persistent | Temporary, resets on restart |
| **I/O Pattern** | Read + Write (OLTP) | Write-heavy (append) | Memory-only |
| **Pressure Type** | Disk + IOPS | Disk space | Memory |
| **Degradation** | Query latency | Search slowness | OOM crash |
| **Production Analog** | RDS/Aurora under load | CloudWatch Logs, ELK | Container memory limits |
| **Observable** | Cache ratio, query time | Index size, disk usage | Heap metrics, GC |
| **Recovery** | Cleanup/archival needed | Delete old indices | Restart clears |

---

## Troubleshooting

### Database Not Growing

**Check if accounting service is running:**

```bash
# Docker Compose
docker ps | grep accounting

# Kubernetes
kubectl get pod -n otel-demo | grep accounting
```

**Check if orders are being processed:**

```bash
# Docker Compose
docker logs accounting | grep -i "order received"

# Kubernetes
kubectl logs -n otel-demo -l app.kubernetes.io/name=accounting | grep -i "order received"
```

**Check Kafka connectivity:**

```bash
# Docker Compose
docker logs accounting | grep -i kafka

# Kubernetes
kubectl logs -n otel-demo -l app.kubernetes.io/name=accounting | grep -i kafka
```

**Verify flag is enabled:**
- Go to FlagD UI: http://localhost:4000
- Check `kafkaQueueProblems` is set to `on` with value `2000`

**Increase load:**
- Raise Locust users from 50 to 75 or 100
- More checkouts = more database writes

### Database Growing Too Slowly

**Increase flag value:**
- Change from 2000 to 5000 or 10000
- More Kafka messages per checkout = faster growth

**Increase traffic:**
- More Locust users = more checkouts per minute
- Longer runtime = more cumulative data

### Not Seeing I/O Pressure

**Database may be cached in memory:**
- Postgres container has 80MB memory limit
- Most data may fit in cache
- Try running longer to accumulate more data

**Reduce Postgres memory limit (Kubernetes only):**

```bash
# Lower memory limit to force more disk I/O
kubectl set resources deployment postgresql -n otel-demo --limits=memory=40Mi

# Watch for increased I/O pressure
kubectl top pod -n otel-demo | grep postgresql
```

**Check disk I/O is being measured:**
- Verify Postgres metrics are flowing to Honeycomb
- Check if `blk_read_time` and `blk_write_time` are increasing

### Connection Pool Exhausted

**Check current connections:**

```bash
# Docker Compose
docker exec postgresql psql -U root -d otelu -c "SELECT count(*) FROM pg_stat_activity WHERE datname='otelu';"

# Kubernetes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otelu -c "SELECT count(*) FROM pg_stat_activity WHERE datname='otelu';"
```

**Increase max connections (temporary fix):**

```bash
# Docker Compose
docker exec postgresql psql -U root -c "ALTER SYSTEM SET max_connections = 200;"
docker restart postgresql

# Kubernetes
kubectl exec -n otel-demo postgresql-0 -- psql -U root -c "ALTER SYSTEM SET max_connections = 200;"
kubectl rollout restart statefulset postgresql -n otel-demo
```

---

## Cleanup

### Stop Load Test

1. Go to Locust UI: http://localhost:8089
2. Click **"Stop"** button

### Disable Feature Flag

1. Go to FlagD UI: http://localhost:4000
2. Set `kafkaQueueProblems` back to **`off`**

### Clear Database (to reclaim disk space)

**For Docker Compose:**

```bash
# Drop and recreate database
docker exec postgresql psql -U root -c "DROP DATABASE IF EXISTS otelu;"
docker exec postgresql psql -U root -c "CREATE DATABASE otelu;"

# Or restart with volume removal
docker compose down -v
docker compose up -d
```

**For Kubernetes:**

```bash
# Delete and recreate the database
kubectl exec -n otel-demo postgresql-0 -- psql -U root -c "DROP DATABASE IF EXISTS otelu;"
kubectl exec -n otel-demo postgresql-0 -- psql -U root -c "CREATE DATABASE otelu;"

# Or delete the PVC to clear all data
kubectl delete pvc postgresql-data -n otel-demo
kubectl delete pod postgresql-0 -n otel-demo
# StatefulSet will recreate with fresh volume
```

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **Database disk growth** from high transaction volume
2. ✅ **I/O pressure patterns** (read/write latency increasing)
3. ✅ **Cache effectiveness degradation** under load
4. ✅ **Query latency correlation** with table size
5. ✅ **Transactional workload impact** on storage
6. ✅ **Database metrics** for capacity planning
7. ✅ **Application-level observability** of database bottlenecks
8. ✅ **Trace correlation** showing database as bottleneck
9. ✅ **Real-world RDS/Aurora** performance patterns

---

## Key Takeaways

### For Database Administrators:

- **Monitor table growth** proactively (not just database size)
- **Cache hit ratio** is critical indicator of I/O pressure
- **Write latency** degradation appears before disk exhaustion
- **Index bloat** contributes significantly to disk usage
- **Connection pool** sizing matters under sustained load

### For Application Engineers:

- **Async processing** (Kafka → accounting) doesn't eliminate database pressure
- **Batch writes** could reduce I/O pressure (vs one-by-one INSERTs)
- **Database latency** impacts upstream services even when async
- **Monitoring both app and DB** metrics provides complete picture

### For SREs/Platform Engineers:

- **Disk IOPS** can be bottleneck before disk space
- **Sustained write workloads** behave differently than read-heavy
- **Database growth** is cumulative (unlike memory which resets)
- **Alerting on growth rate** catches issues before outages
- **RDS IOPS limits** can cause similar patterns in production

---

## Production Scenarios Simulated

This demo replicates these real-world issues:

1. **RDS Disk Exhaustion** - High transaction volume fills database
2. **IOPS Quota Exceeded** - Sustained writes hit I/O limits
3. **EBS Volume Growth** - Database volume approaching capacity
4. **Cache Pressure** - Working set exceeds available memory
5. **Query Degradation** - Large tables slow down queries
6. **Write Amplification** - Each transaction creates multiple rows

---

## Next Steps

### Extend the Use Case

1. **Add database monitoring:**
   - Export Postgres metrics to Honeycomb
   - Monitor `pg_stat_statements` for slow queries
   - Track index usage and bloat

2. **Implement archival strategy:**
   - Partition tables by date
   - Archive old orders to S3/object storage
   - Demonstrate cleanup and recovery

3. **Test with read queries:**
   - Add query workload to accounting service
   - Observe read latency under disk pressure
   - Compare read vs write performance

4. **Simulate IOPS limits:**
   - Use `ionice` to limit I/O bandwidth
   - Observe behavior under throttled I/O
   - More realistic RDS/EBS simulation

5. **Create SLO for database performance:**
   - Define acceptable query latency (e.g., P95 < 100ms)
   - Track error budget burn during growth
   - Demonstrate capacity planning

---

## References

- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [Honeycomb Query Language](https://docs.honeycomb.io/query-data/)
- [PostgreSQL Statistics Collector](https://www.postgresql.org/docs/current/monitoring-stats.html)
- [AWS RDS Performance Insights](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.html)
- [OpenTelemetry Database Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/database/)

---

## Summary

This use case demonstrates **Postgres disk and IOPS pressure** using:

- ✅ Feature flag for dynamic control (`kafkaQueueProblems`)
- ✅ Zero code changes required
- ✅ Realistic OLTP workload simulation
- ✅ Observable in Honeycomb with database metrics
- ✅ Cumulative, persistent growth (unlike memory scenarios)
- ✅ I/O pressure patterns similar to RDS/Aurora
- ✅ Trace correlation showing database bottlenecks
- ✅ Dashboard with latency trends and cache metrics
- ✅ Alert configuration for capacity and performance
- ✅ Simulates production storage/IOPS constraints

**Key difference from memory scenarios:** This demonstrates **persistent storage growth and I/O pressure** rather than temporary memory exhaustion - a critical pattern for database capacity planning and performance troubleshooting.
