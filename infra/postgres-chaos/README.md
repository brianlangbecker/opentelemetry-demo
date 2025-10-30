# PostgreSQL Chaos Engineering Scripts

Database stress testing and chaos engineering tools for observability demos.

## Scripts

### Automated Chaos
- **beast-mode-chaos.sql** - 30-minute sustained chaos test (900 cycles)
  - Creates massive table bloat via UPDATEs
  - Forces cache misses with heavy JOINs
  - Real-time monitoring and progress reporting
- **run-beast-mode.sh** - Wrapper script to run beast mode

### Interactive Chaos
- **postgres-chaos-queries.sql** - Manual chaos scenarios
  - Table locks, row locks, slow queries
  - Bloat generation, analytics queries
  - Connection exhaustion, statistics invalidation
- **run-postgres-chaos.sh** - Interactive menu with 12 scenarios
  - Built-in monitoring (locks, bloat, slow queries)
  - Manual VACUUM FULL option

## Documentation

- **BEAST-MODE-README.md** - Complete guide with cleanup procedures
- **heavy-maintenance-chaos.md** - Heavy maintenance scenario details

## Quick Start

```bash
# From infra directory:

# Run 30-minute automated chaos
./postgres-chaos/run-beast-mode.sh

# Or run interactive menu
./postgres-chaos/run-postgres-chaos.sh
```

## Cleanup

After running chaos tests, manually clean up bloat:

```bash
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n otel-demo $POD -- psql -U root -d otel -c "VACUUM FULL ANALYZE orderitem;"
```

See BEAST-MODE-README.md for detailed cleanup instructions.
