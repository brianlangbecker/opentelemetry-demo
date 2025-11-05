# pgbench - PostgreSQL Load Testing

High-performance database load testing tools for the OpenTelemetry Demo.

---

## Quick Start

```bash
cd infra/pgbench/

# Load Testing
./pgbench.sh light    # Quick 30-second test
./pgbench.sh normal   # Standard 5-10 minute load test
./pgbench.sh beast    # Extreme 30+ minute stress test (may crash pod)

# Failure Scenarios (Observability Testing)
./pgbench.sh demo                # Run all 3 scenarios (10 min total)
./pgbench.sh connection-exhaust  # Exhaust connection pool (5 min)
./pgbench.sh table-lock          # Lock critical table (3 min)
./pgbench.sh slow-query          # Expensive queries (5 min)
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| **pgbench.sh** | Main script - run PostgreSQL load tests and failure scenarios |
| **PGBENCH-README.md** | Detailed pgbench documentation and usage |
| **PGBENCH-BLAST-RADIUS.md** | Service impact analysis for load tests |
| **POSTGRES-LOAD-TESTING.md** | Overall load testing strategy |
| **DATABASE-FAILURE-SCENARIOS.md** | Database failure scenarios for observability testing |
| **DATABASE-BLOAT-INCIDENT.md** | Real incident: 7.5GB database causing 40x performance degradation |
| **HONEYCOMB-BLAST-RADIUS-QUERIES.md** | Complete guide to querying Honeycomb for blast radius analysis |
| **README.md** | This file - directory overview |

---

## Load Testing Modes

### ⚡ Light (30 seconds)
- **Use for:** Quick verification
- **Impact:** Minimal - CPU ~20-40%
- **Command:** `./pgbench.sh light`

### 🔥 Normal (5-10 minutes)
- **Use for:** Realistic load testing, demos
- **Impact:** Moderate - CPU 60-80%
- **Command:** `./pgbench.sh normal`

### 💀 Beast (30+ minutes)
- **Use for:** Chaos engineering, failure testing
- **Impact:** EXTREME - Will likely cause OOMKill
- **Command:** `./pgbench.sh beast`

---

## Failure Scenario Modes

### 🎬 Demo Mode (10 minutes) - **RECOMMENDED**
- **Use for:** Complete observability demo
- **Impact:** Runs all 3 scenarios sequentially with recovery pauses
- **Observability:** Shows connection errors → lock waits → CPU saturation
- **Command:** `./pgbench.sh demo`
- **Timeline:**
  - T+0-3: Connection exhaustion
  - T+3-4: Recovery pause
  - T+4-6: Table lock
  - T+6-7: Recovery pause
  - T+7-10: Slow query

### 🔌 Connection Exhaustion (5 minutes)
- **Use for:** Demonstrate connection pool problems
- **Impact:** 95 idle connections, "too many clients" errors
- **Observability:** Connection errors without CPU spike
- **Command:** `./pgbench.sh connection-exhaust`

### 🔒 Table Lock (3 minutes)
- **Use for:** Show query blocking vs performance issues
- **Impact:** Locks pgbench_accounts table, queries timeout
- **Observability:** High query duration without errors
- **Command:** `./pgbench.sh table-lock`

### 🐌 Slow Query (5 minutes)
- **Use for:** Demonstrate expensive query patterns
- **Impact:** Full table scans, CPU 80-100%
- **Observability:** Slow queries with high CPU
- **Command:** `./pgbench.sh slow-query`

---

## What Gets Affected?

When you run pgbench, the blast radius extends beyond just PostgreSQL:

1. **PostgreSQL** - Direct impact (CPU, memory, connections)
2. **accounting** - Primary consumer of PostgreSQL
3. **checkout** - Depends on accounting via Kafka
4. **frontend** - User-facing checkout failures
5. **10+ other services** - Cascading slowdowns

See [PGBENCH-BLAST-RADIUS.md](./PGBENCH-BLAST-RADIUS.md) for complete service impact analysis.

---

## Observability

All load tests generate rich telemetry visible in Honeycomb:

- **Metrics dataset:** PostgreSQL CPU, memory, connections
- **k8s-events dataset:** Pod restarts, OOMKills
- **Service datasets:** Database query performance, error rates

---

## Additional Commands

```bash
# Initialize pgbench tables manually
./pgbench.sh init

# Check table status
./pgbench.sh status

# Clean up pgbench tables
./pgbench.sh clean
```

---

## Documentation

### Getting Started
- **New to pgbench?** Start with [PGBENCH-README.md](./PGBENCH-README.md)
- **Planning a demo?** Read [POSTGRES-LOAD-TESTING.md](./POSTGRES-LOAD-TESTING.md)

### Testing & Scenarios
- **Want to understand impact?** See [PGBENCH-BLAST-RADIUS.md](./PGBENCH-BLAST-RADIUS.md)
- **Testing observability?** See [DATABASE-FAILURE-SCENARIOS.md](./DATABASE-FAILURE-SCENARIOS.md)

### Troubleshooting & Analysis
- **Database performance issues?** See [DATABASE-BLOAT-INCIDENT.md](./DATABASE-BLOAT-INCIDENT.md)
- **How to query Honeycomb?** See [HONEYCOMB-BLAST-RADIUS-QUERIES.md](./HONEYCOMB-BLAST-RADIUS-QUERIES.md)

---

## Tips

1. **Always start small** - Run `light` before `beast`
2. **Monitor in Honeycomb** - Watch CPU/memory/latency in real-time
3. **Expect failures in beast mode** - That's the point!
4. **Kafka backlogs are normal** - The accounting service may lag during high load
5. **Run failure scenarios separately** - Don't overlap connection-exhaust + table-lock
6. **Use scenarios for demos** - Show how to diagnose different database problems
7. **Always cleanup after testing** - Run `./pgbench.sh clean` after beast/high-scale tests
8. **Check database size regularly** - Run `./pgbench.sh status` to monitor bloat

## ⚠️ Important Warnings

**Database Bloat:** If checkout latency suddenly jumps from <100ms to >1 second, check database size:
```bash
./pgbench.sh status
```

If database is >1GB, clean immediately:
```bash
./pgbench.sh clean
```

See [DATABASE-BLOAT-INCIDENT.md](./DATABASE-BLOAT-INCIDENT.md) for the full story of a 40x performance degradation caused by a 7.5GB database!

---

**Ready to test?**
- For load testing: `./pgbench.sh light`
- For observability demo: `./pgbench.sh demo` (10 minutes, shows all failure patterns) 🚀
