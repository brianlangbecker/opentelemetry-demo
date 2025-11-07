# PostgreSQL Chaos Testing

High-performance database chaos testing and load generation tools for the OpenTelemetry Demo.

---

## Quick Start

```bash
cd infra/postgres-chaos/

# Load Testing
./postgres-chaos-scenarios.sh light    # Quick 30-second test
./postgres-chaos-scenarios.sh normal   # Standard 5-10 minute load test
./postgres-chaos-scenarios.sh beast    # Extreme 30+ minute stress test (may crash pod)

# Chaos Scenarios (Observability Testing)
./postgres-chaos-scenarios.sh demo                # Run all 3 scenarios (10 min total)
./postgres-chaos-scenarios.sh connection-exhaust  # Exhaust connection pool (5 min)
./postgres-chaos-scenarios.sh table-lock          # Lock critical tables (10 min)
./postgres-chaos-scenarios.sh slow-query          # Expensive queries on products table (30 min)
```

---

## Directory Structure

```
postgres-chaos/
├── postgres-chaos-scenarios.sh  # Main script - run all tests and scenarios
├── accounting-load.sql           # Custom workload for accounting tables
├── README.md                     # This file - quick reference
└── docs/                         # Detailed documentation
    ├── POSTGRES-CHAOS-README.md             # Comprehensive usage guide
    ├── POSTGRES-CHAOS-SCENARIOS.md          # Chaos testing scenarios
    ├── POSTGRES-LOAD-TESTING.md             # Load testing strategy
    ├── DATABASE-BLOAT-INCIDENT.md           # Real incident analysis
    └── HONEYCOMB-BLAST-RADIUS-QUERIES.md    # Honeycomb query guide
```

---

## Load Testing Modes

### ⚡ Light (30 seconds)

- **Use for:** Quick verification
- **Impact:** Minimal - CPU ~20-40%
- **Command:** `./postgres-chaos-scenarios.sh light`

### 🔥 Normal (5-10 minutes)

- **Use for:** Realistic load testing, demos
- **Impact:** Moderate - CPU 60-80%
- **Command:** `./postgres-chaos-scenarios.sh normal`

### 💀 Beast (30+ minutes)

- **Use for:** Chaos engineering, failure testing
- **Impact:** EXTREME - Will likely cause OOMKill
- **Command:** `./postgres-chaos-scenarios.sh beast`

---

## Chaos Scenario Modes

### 🎬 Demo Mode (10 minutes) - **RECOMMENDED**

- **Use for:** Complete observability demo
- **Impact:** Runs all 3 scenarios sequentially with recovery pauses
- **Observability:** Shows connection errors → lock waits → CPU saturation
- **Command:** `./postgres-chaos-scenarios.sh demo`
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
- **Affects:** Both accounting and product-catalog services simultaneously
- **Command:** `./postgres-chaos-scenarios.sh connection-exhaust`

### 🔒 Table Lock (10 minutes)

- **Use for:** Show query blocking vs performance issues
- **Impact:** Locks `order` and `products` tables
- **Observability:** High query duration without errors
- **Affects:** accounting (order table) and product-catalog (products table) differently
- **Command:** `./postgres-chaos-scenarios.sh table-lock`

### 🐌 Slow Query (30 minutes)

- **Use for:** Demonstrate expensive query patterns
- **Impact:** Full table scans on products table, CPU 80-100%
- **Observability:** Slow queries with high CPU across all database consumers
- **Affects:** ALL database consumers (accounting, product-catalog)
- **Command:** `./postgres-chaos-scenarios.sh slow-query`

---

## Blast Radius

When you run chaos scenarios, the blast radius extends across multiple services:

### Direct PostgreSQL Consumers
1. **accounting** - Writes to `order` and `orderitem` tables
2. **product-catalog** - Reads from `products` table

### Cascading Failures
3. **checkout** - Depends on both accounting (via Kafka) and product-catalog (direct)
4. **frontend** - Depends on product-catalog for product listings
5. **Other services** - Recommendation, cart, etc.

See [docs/POSTGRES-CHAOS-SCENARIOS.md](./docs/POSTGRES-CHAOS-SCENARIOS.md) for complete multi-service impact analysis.

---

## Observability

All chaos tests generate rich telemetry visible in Honeycomb:

- **Metrics dataset:** PostgreSQL CPU, memory, connections
- **k8s-events dataset:** Pod restarts, OOMKills
- **Service datasets:** 
  - accounting: Database query performance, error rates
  - product-catalog: Database query performance, product lookup latency
  - checkout: Cascading impact from both services
  - frontend: User-facing impact

---

## Additional Commands

```bash
# Initialize pgbench tables manually
./postgres-chaos-scenarios.sh init

# Check table status and database size
./postgres-chaos-scenarios.sh status

# Clean up pgbench tables
./postgres-chaos-scenarios.sh clean
```

---

## Documentation

### 📚 Getting Started

- **New to postgres-chaos?** Start with [docs/POSTGRES-CHAOS-README.md](./docs/POSTGRES-CHAOS-README.md)
- **Planning a demo?** Read [docs/POSTGRES-LOAD-TESTING.md](./docs/POSTGRES-LOAD-TESTING.md)

### 🧪 Chaos Testing

- **Chaos scenarios explained:** [docs/POSTGRES-CHAOS-SCENARIOS.md](./docs/POSTGRES-CHAOS-SCENARIOS.md)
  - Connection exhaustion vs table locks vs slow queries
  - Multi-service impact patterns (accounting + product-catalog)
  - Symmetric vs asymmetric failures
  - Honeycomb queries for each scenario

### 🔍 Troubleshooting & Analysis

- **Real incident analysis:** [docs/DATABASE-BLOAT-INCIDENT.md](./docs/DATABASE-BLOAT-INCIDENT.md)
  - 7.5GB database causing 40x performance degradation
  - Root cause analysis and resolution
  
- **Honeycomb query guide:** [docs/HONEYCOMB-BLAST-RADIUS-QUERIES.md](./docs/HONEYCOMB-BLAST-RADIUS-QUERIES.md)
  - Step-by-step debugging workflow
  - Pre-built queries for blast radius analysis
  - Multi-service correlation techniques

---

## Tips

1. **Always start small** - Run `light` before `beast`
2. **Monitor multiple services** - Watch accounting, product-catalog, checkout, frontend
3. **Expect failures in beast mode** - That's the point!
4. **Run scenarios separately** - Don't overlap connection-exhaust + table-lock
5. **Use scenarios for demos** - Show how to diagnose different database problems
6. **Clean up after testing** - Run `./postgres-chaos-scenarios.sh clean` after tests
7. **Check database size regularly** - Run `./postgres-chaos-scenarios.sh status` to monitor bloat

---

## ⚠️ Important Warnings

**Database Bloat:** If checkout latency suddenly jumps from <100ms to >1 second, check database size:

```bash
./postgres-chaos-scenarios.sh status
```

If database is >1GB, clean immediately:

```bash
./postgres-chaos-scenarios.sh clean
```

See [docs/DATABASE-BLOAT-INCIDENT.md](./docs/DATABASE-BLOAT-INCIDENT.md) for a real-world example of 40x performance degradation!

---

## Quick Reference

| Command | Purpose | Duration | Primary Impact |
|---------|---------|----------|----------------|
| `light` | Quick verification | 30s | Minimal |
| `normal` | Demo load test | 5-10 min | Moderate |
| `beast` | Chaos engineering | 30+ min | Extreme (OOMKill) |
| `demo` | All scenarios | 10 min | Progressive chaos |
| `connection-exhaust` | Connection pool exhaustion | 5 min | accounting + product-catalog |
| `table-lock` | Table locking | 10 min | Specific tables |
| `slow-query` | Expensive queries | 30 min | ALL consumers |
| `init` | Initialize pgbench | 1 min | Setup |
| `status` | Check database size | 10s | Info only |
| `clean` | Remove pgbench tables | 10s | Cleanup |

---

**Ready to test?**

- **For load testing:** `./postgres-chaos-scenarios.sh light`
- **For chaos demo:** `./postgres-chaos-scenarios.sh demo` (10 minutes, shows all failure patterns) 🚀
- **For documentation:** Check `docs/` directory for detailed guides
