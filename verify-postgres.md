# Verify Postgres Database is Running and Being Used

This document provides commands to verify that PostgreSQL is actually running and receiving data in the OpenTelemetry Demo.

## Quick Verification Commands

### 1. Check if Postgres Container is Running

**Docker Compose:**
```bash
docker ps | grep postgresql
```

**Expected output:**
```
CONTAINER ID   IMAGE                                    COMMAND                  CREATED       STATUS       PORTS                    NAMES
abc123def456   ghcr.io/open-telemetry/demo:1.x-postgresql   "docker-entrypoint.s…"   5 minutes ago Up 5 minutes 0.0.0.0:5432->5432/tcp   postgresql
```

**Kubernetes:**
```bash
kubectl get pod -n otel-demo | grep postgresql
```

**Expected output:**
```
NAME          READY   STATUS    RESTARTS   AGE
postgresql-0   1/1     Running   0          10m
```

---

## 2. Verify Database Connection

**Docker Compose:**
```bash
docker exec postgresql psql -U root -d otel -c "SELECT version();"
```

**Expected output:**
```
                                                 version
---------------------------------------------------------------------------------------------------------
 PostgreSQL 17.6 (Debian 17.6-1.pgdg120+1) on x86_64-pc-linux-gnu, compiled by gcc (Debian 12.2.0-14) 12.2.0, 64-bit
(1 row)
```

**Kubernetes:**
```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT version();"
```

---

## 3. List All Tables (Verify Schema Created)

**Docker Compose:**
```bash
docker exec postgresql psql -U root -d otel -c "\dt"
```

**Expected output:**
```
          List of relations
 Schema |   Name    | Type  | Owner
--------+-----------+-------+-------
 public | order     | table | root
 public | orderitem | table | root
 public | shipping  | table | root
(3 rows)
```

**Kubernetes:**
```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "\dt"
```

---

## 4. Check Table Row Counts (Prove Data is Being Written)

**Docker Compose:**
```bash
docker exec postgresql psql -U root -d otel -c "
SELECT
    'order' as table_name, COUNT(*) as row_count FROM \"order\"
UNION ALL
SELECT 'orderitem', COUNT(*) FROM orderitem
UNION ALL
SELECT 'shipping', COUNT(*) FROM shipping
ORDER BY table_name;
"
```

**Expected output (after orders placed):**
```
 table_name | row_count
------------+-----------
 order      |        42
 orderitem  |       123
 shipping   |        42
(3 rows)
```

**Kubernetes:**
```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "
SELECT
    'order' as table_name, COUNT(*) as row_count FROM \"order\"
UNION ALL
SELECT 'orderitem', COUNT(*) FROM orderitem
UNION ALL
SELECT 'shipping', COUNT(*) FROM shipping
ORDER BY table_name;
"
```

---

## 5. View Recent Orders (Verify Active Writes)

**Docker Compose:**
```bash
docker exec postgresql psql -U root -d otel -c "
SELECT
    o.order_id,
    COUNT(oi.product_id) as item_count,
    s.city,
    s.state
FROM \"order\" o
LEFT JOIN orderitem oi ON o.order_id = oi.order_id
LEFT JOIN shipping s ON o.order_id = s.order_id
GROUP BY o.order_id, s.city, s.state
ORDER BY o.order_id DESC
LIMIT 10;
"
```

**Expected output:**
```
           order_id            | item_count |     city      | state
-------------------------------+------------+---------------+-------
 550e8400-e29b-41d4-a716-...  |          3 | San Francisco | CA
 6ba7b810-9dad-11d1-80b4-...  |          2 | New York      | NY
 6ba7b811-9dad-11d1-80b4-...  |          1 | Seattle       | WA
...
```

**Kubernetes:**
```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "
SELECT
    o.order_id,
    COUNT(oi.product_id) as item_count,
    s.city,
    s.state
FROM \"order\" o
LEFT JOIN orderitem oi ON o.order_id = oi.order_id
LEFT JOIN shipping s ON o.order_id = s.order_id
GROUP BY o.order_id, s.city, s.state
ORDER BY o.order_id DESC
LIMIT 10;
"
```

---

## 6. Watch Real-Time Order Inserts

**Docker Compose:**
```bash
# Terminal 1: Watch database row count
watch -n 2 'docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) as total_orders FROM \"order\";"'

# Terminal 2: Generate load (browse demo or use Locust)
# http://localhost:8080
# http://localhost:8089
```

**Expected behavior:**
- Row count increases as you place orders
- Proves accounting service is writing to database

**Kubernetes:**
```bash
# Terminal 1: Watch database row count
watch -n 2 'kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "SELECT COUNT(*) as total_orders FROM \"order\";"'

# Terminal 2: Generate load
```

---

## 7. Verify Accounting Service is Connected

**Check accounting service logs for database activity:**

**Docker Compose:**
```bash
docker logs accounting 2>&1 | grep -i "database\|postgres\|order received" | tail -20
```

**Expected output:**
```
[timestamp] info: Accounting.Consumer[0] Order received - ID: 550e8400-e29b-41d4-a716-...
[timestamp] info: Microsoft.EntityFrameworkCore.Database.Command[20101] Executed DbCommand (5ms)
```

**Kubernetes:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=accounting | grep -i "order received" | tail -20
```

---

## 8. Check Database Connection String

**Docker Compose:**
```bash
docker exec accounting env | grep DB_CONNECTION_STRING
```

**Expected output:**
```
DB_CONNECTION_STRING=Host=postgresql;Username=otelu;Password=otelp;Database=otel
```

**Kubernetes:**
```bash
kubectl exec -n otel-demo deployment/accounting -- env | grep DB_CONNECTION_STRING
```

---

## 9. Verify Database Size Growth

**Docker Compose:**
```bash
docker exec postgresql psql -U root -d otel -c "
SELECT
    pg_database.datname,
    pg_size_pretty(pg_database_size(pg_database.datname)) AS size
FROM pg_database
WHERE datname = 'otel';
"
```

**Expected output:**
```
 datname | size
---------+-------
 otel    | 8192 kB
(1 row)
```

**Kubernetes:**
```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "
SELECT
    pg_database.datname,
    pg_size_pretty(pg_database_size(pg_database.datname)) AS size
FROM pg_database
WHERE datname = 'otel';
"
```

---

## 10. Check pg_stat_database (I/O Metrics)

**Docker Compose:**
```bash
docker exec postgresql psql -U root -d otel -c "
SELECT
    datname,
    numbackends as connections,
    xact_commit as commits,
    xact_rollback as rollbacks,
    blks_read as disk_reads,
    blks_hit as cache_hits,
    tup_inserted as inserts,
    tup_updated as updates,
    tup_deleted as deletes
FROM pg_stat_database
WHERE datname = 'otel';
"
```

**Expected output:**
```
 datname | connections | commits | rollbacks | disk_reads | cache_hits | inserts | updates | deletes
---------+-------------+---------+-----------+------------+------------+---------+---------+---------
 otel    |           2 |    1234 |         0 |        145 |      98765 |    3702 |       0 |       0
(1 row)
```

**What proves it's working:**
- `commits > 0` - Transactions are being committed
- `inserts > 0` - Data is being inserted
- `cache_hits` is much higher than `disk_reads` - Database is active

**Kubernetes:**
```bash
kubectl exec -n otel-demo postgresql-0 -- psql -U root -d otel -c "
SELECT
    datname,
    numbackends as connections,
    xact_commit as commits,
    xact_rollback as rollbacks,
    blks_read as disk_reads,
    blks_hit as cache_hits,
    tup_inserted as inserts,
    tup_updated as updates,
    tup_deleted as deletes
FROM pg_stat_database
WHERE datname = 'otel';
"
```

---

## 11. Test End-to-End Flow

### Complete Verification Workflow:

```bash
# 1. Check baseline row count
docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"

# 2. Place an order via the demo UI
# Open http://localhost:8080
# Add items to cart and checkout

# 3. Wait 2-3 seconds for accounting service to process Kafka message

# 4. Check row count again
docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"

# Expected: Row count increased by 1
```

---

## 12. Verify Kafka → Accounting → Postgres Flow

**Watch the complete flow:**

```bash
# Terminal 1: Watch Kafka messages
docker logs kafka --tail 10 -f | grep orders

# Terminal 2: Watch accounting service processing
docker logs accounting --tail 10 -f | grep "Order received"

# Terminal 3: Watch database inserts
watch -n 1 'docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"'

# Terminal 4: Generate orders via Locust or UI
# http://localhost:8089
```

---

## 13. Detailed Table Statistics

**Docker Compose:**
```bash
docker exec postgresql psql -U root -d otel -c "
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS index_size,
    (SELECT count(*) FROM pg_stat_user_tables WHERE schemaname||'.'||tablename = pg_stat_user_tables.schemaname||'.'||pg_stat_user_tables.relname) as row_estimate
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
"
```

**Expected output:**
```
 schemaname | tablename | total_size | table_size | index_size | row_estimate
------------+-----------+------------+------------+------------+--------------
 public     | orderitem |    128 kB  |     64 kB  |    64 kB   |            1
 public     | order     |     64 kB  |     32 kB  |    32 kB   |            1
 public     | shipping  |     64 kB  |     32 kB  |    32 kB   |            1
(3 rows)
```

---

## 14. Verify OpenTelemetry Collector Scraping Postgres Metrics

**Check if OTel Collector is scraping Postgres (Kubernetes only):**

```bash
kubectl logs -n otel-demo deployment/otel-collector | grep -i postgres | tail -20
```

**Expected:** Logs showing PostgreSQL receiver scraping metrics

---

## Summary: Quick Proof Commands

**Fastest way to prove Postgres is working:**

```bash
# 1. Is container running?
docker ps | grep postgresql

# 2. Can we connect?
docker exec postgresql psql -U root -d otel -c "SELECT 1;"

# 3. Do tables exist?
docker exec postgresql psql -U root -d otel -c "\dt"

# 4. Is data being written?
docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"

# 5. Watch it grow in real-time (place orders via UI)
watch -n 2 'docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"'
```

---

## Troubleshooting

### No Data in Database

**Check if accounting service has DB connection:**
```bash
docker logs accounting | grep "DB_CONNECTION_STRING"
```

If you see warnings about null connection string, the accounting service isn't configured to use Postgres.

**Check environment variable:**
```bash
docker exec accounting env | grep DB_CONNECTION_STRING
```

### Database Exists But Empty

**Check Kafka connectivity:**
```bash
docker logs accounting | grep -i kafka
```

Accounting service needs Kafka to receive order messages.

**Manually trigger an order:**
1. Go to http://localhost:8080
2. Add items to cart
3. Complete checkout
4. Wait 5 seconds
5. Run: `docker exec postgresql psql -U root -d otel -c "SELECT COUNT(*) FROM \"order\";"`

---

## References

- [PostgreSQL Documentation](https://www.postgresql.org/docs/current/)
- [pg_stat_database view](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW)
- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
