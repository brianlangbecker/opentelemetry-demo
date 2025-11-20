# Chaos Engineering Scenarios

Ready-to-use chaos engineering guides for the OpenTelemetry Demo. All scenarios require **zero code changes**.

## Available Scenarios

### Memory & Resource Exhaustion

| Scenario | File | Target | Options |
|----------|------|--------|---------|
| Memory Chaos | [MEMORY-CHAOS.md](MEMORY-CHAOS.md) | Checkout (Go), Ad Service (Java) | Spike (60-90s), Leak (10-20m), GC Thrashing (continuous) |

### Disk & Storage Pressure

| Scenario | File | Target | Time to Failure |
|----------|------|--------|-----------------|
| Filesystem Growth | [filesystem-growth-crash-simple.md](filesystem-growth-crash-simple.md) | OpenSearch | 2-3 hours |
| Database Chaos | [DATABASE-CHAOS.md](DATABASE-CHAOS.md) | PostgreSQL | Multiple options: organic (2-4h), fast (1-2h), immediate, table locks (10min) |

### Infrastructure Failures

See [OBSERVABILITY-PATTERNS.md](OBSERVABILITY-PATTERNS.md) for DNS failure scenarios (complete failure vs capacity issues)

### Observability & Alerting

| Guide | Purpose |
|-------|---------|
| [OBSERVABILITY-PATTERNS.md](OBSERVABILITY-PATTERNS.md) | What you can observe during crashes and DNS issues + recommended alerts/SLOs |

## Quick Start

1. Choose a scenario from the tables above
2. Read the guide (each is self-contained)
3. Follow the step-by-step instructions
4. Monitor in Honeycomb using provided queries

## What Each Scenario Includes

- Overview and prerequisites
- Technical explanation
- Execution steps for Kubernetes
- Honeycomb queries (5-10 essential queries)
- Expected timeline
- Troubleshooting tips
- Cleanup instructions

## Use Cases

- **Training**: Teach observability and incident response
- **Demos**: Showcase monitoring capabilities
- **Testing**: Validate alerts and dashboards
- **SRE Practice**: Chaos engineering exercises

## Related Resources

- [../infra/README.md](../infra/README.md) - Infrastructure setup guide
- [Chaos Engineering Principles](https://principlesofchaos.org/)
- [Honeycomb Documentation](https://docs.honeycomb.io)
