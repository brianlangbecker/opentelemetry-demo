# Beast Mode Chaos Scripts

SQL scripts to stress test PostgreSQL and create observable database issues in Honeycomb.

## What These Scripts Do

1. **Create massive table bloat** - No-op UPDATEs create dead tuples without VACUUM cleaning them up
2. **Force cache misses** - Heavy JOINs with random ordering cause disk I/O pressure
3. **Degrade performance** - Cache hit ratio drops, query latency increases, IOPS spike

## Files

- **beast-mode-chaos.sql** - Full 6-minute test (180 cycles × 2s)
- **beast-mode-chaos-quick.sql** - Quick 2-minute test (30 cycles × 4s) - DEPRECATED, use main script instead
- **run-beast-mode.sh** - Helper script to run the full test

## Quick Start

### Option 1: Using the helper script (recommended)

```bash
cd infra
./run-beast-mode.sh
```

### Option 2: Manual execution

```bash
# Get pod name
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

# Run quick test (2 minutes)
kubectl cp beast-mode-chaos-quick.sql otel-demo/$POD:/tmp/chaos.sql
kubectl exec -n otel-demo $POD -- psql -U root -d otel -f /tmp/chaos.sql

# Run full test (24 minutes)
kubectl cp beast-mode-chaos.sql otel-demo/$POD:/tmp/chaos.sql
kubectl exec -n otel-demo $POD -- psql -U root -d otel -f /tmp/chaos.sql
```

## Expected Output

```
==========================================
BEAST MODE CHAOS - STARTING
This will create REAL database chaos:
  - Massive UPDATE bloat (dead tuples)
  - Heavy queries (cache misses)
  - Lock contention
  - Disk I/O pressure
Duration: 180 cycles × 2s = 6 minutes
==========================================

[20:04:49] Cycle 1/180 | Dead: 25900 | Bloat: 12217.0% | Table: 21 MB | Elapsed: 0s
[20:05:37] Cycle 21/180 | Dead: 25900 | Bloat: 12217.0% | Table: 21 MB | Elapsed: 48s

========== 33 complete ==========
Real dead tuples: 25900
Bloat percentage: 12217.0%
Table size: 21 MB

...

==========================================
BEAST MODE COMPLETE!
Final dead tuples: 25900
Final bloat: 12217.0%
Final table size: 25 MB
Total time: 437 seconds
==========================================

Cleanup: VACUUM FULL ANALYZE orderitem;
```

## What to Monitor in Honeycomb

While the script runs, watch these metrics in the **Metrics** dataset:

### Cache Hit Ratio (Primary Metric)
```
SUM(INCREASE(postgresql.blks_hit)) /
(SUM(INCREASE(postgresql.blks_hit)) + SUM(INCREASE(postgresql.blks_read))) * 100
GROUP BY time(1m)
```
Expected: Starts at 99%, drops to 85-90% during chaos

### Dead Tuples
```
MAX(LAST(postgresql.deadlocks))
GROUP BY time(1m)
```

### Disk I/O Rate
```
SUM(RATE(postgresql.blks_read))
GROUP BY time(1m)
```
Expected: Increases 3-5x during chaos

## Stopping the Script

Press `Ctrl+C` to stop the script early. The database will NOT automatically clean up - you must run cleanup manually.

## Cleanup (IMPORTANT!)

**WARNING**: The script does NOT automatically clean up after completion. Running it multiple times without cleanup will cause cumulative bloat that degrades performance significantly.

### When to Clean Up

- **After each test run** if you plan to run again
- **Before performance testing** to get accurate baseline metrics
- **When database feels slow** - check bloat levels first

### Quick Cleanup Command

```bash
# Get pod name
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

# Run VACUUM FULL to remove bloat and reclaim space
kubectl exec -n otel-demo $POD -- psql -U root -d otel -c "VACUUM FULL ANALYZE orderitem;"
```

**Note**: VACUUM FULL locks the orderitem table for 30-60 seconds and will temporarily block queries.

### Check Current Bloat Level

Before cleanup, check how bad the bloat is:

```bash
kubectl exec -n otel-demo $POD -- psql -U root -d otel -c "
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
  n_live_tup AS live_tuples,
  n_dead_tup AS dead_tuples,
  ROUND(n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100, 1) AS bloat_pct
FROM pg_stat_user_tables
WHERE tablename = 'orderitem';
"
```

Example output after beast mode:
```
 schemaname | tablename | total_size | live_tuples | dead_tuples | bloat_pct
------------+-----------+------------+-------------+-------------+-----------
 public     | orderitem | 25 MB      |         212 |       25900 |   12217.0
```

### What Cleanup Does

1. **Removes dead tuples** (created by UPDATE operations)
2. **Reclaims disk space** (shrinks table back to normal size)
3. **Rebuilds indexes** (improves query performance)
4. **Updates statistics** (helps query planner make better decisions)

### Alternative: Regular VACUUM (Faster, No Lock)

If you need to avoid table locks, use regular VACUUM instead:

```bash
kubectl exec -n otel-demo $POD -- psql -U root -d otel -c "VACUUM ANALYZE orderitem;"
```

**Trade-off**: Removes dead tuples but does NOT reclaim disk space. Table stays bloated but queries speed up.
