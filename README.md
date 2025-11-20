# OpenTelemetry Demo (Fork)

This is a fork of the [official OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo) with custom chaos engineering scenarios.

## Quick Start

**Official Documentation:** https://opentelemetry.io/docs/demo/

**Deployment:**
- [Docker](https://opentelemetry.io/docs/demo/docker_deployment/)
- [Kubernetes](https://opentelemetry.io/docs/demo/kubernetes_deployment/)

## What's Different in This Fork

### Custom Chaos Engineering Scenarios

See [chaos-scenarios/README.md](chaos-scenarios/README.md) for ready-to-use failure scenarios:
- Memory exhaustion and leaks
- JVM GC thrashing
- Disk/storage pressure
- DNS failures
- Database chaos

### Custom Infrastructure Setup

See [infra/README.md](infra/README.md) for:
- Kubernetes deployment with persistent PostgreSQL
- OpenTelemetry Collector sidecar configurations
- Honeycomb integration

## Upstream Repository

**Main Repo:** https://github.com/open-telemetry/opentelemetry-demo

For general documentation, contributing guidelines, and community information, refer to the upstream repository.

---

## Appendix: Fork Differences

This appendix documents the key differences between this fork and the upstream OpenTelemetry Demo repository.

### Chaos Engineering Documentation

**Added:** Comprehensive chaos engineering scenarios with production-ready alerts

| File | Description | Lines |
|------|-------------|-------|
| `chaos-scenarios/MEMORY-CHAOS.md` | Memory spike, gradual leak, JVM GC thrashing (3 scenarios) | 606 |
| `chaos-scenarios/DATABASE-CHAOS.md` | PostgreSQL IOPS pressure, table locks, pre-seeding (2+ scenarios) | 645 |
| `chaos-scenarios/OBSERVABILITY-PATTERNS.md` | Application crash & DNS observability + 17 production alerts + 3 SLOs | 701 |
| `chaos-scenarios/frontend-flood-rate-limiting.md` | Rate limiting demonstration with Envoy | 246 |
| `chaos-scenarios/filesystem-growth-crash-simple.md` | OpenSearch disk exhaustion | 271 |
| `chaos-scenarios/istiod-crash-restart.md` | Istio control plane failures | 616 |

**Total:** 7 chaos scenario guides with 17 production-ready alerts

**Upstream equivalent:** None - original repo has no chaos engineering documentation

---

### Infrastructure Setup

**Added:** Custom Kubernetes deployment configurations with Honeycomb integration

| File | Purpose |
|------|---------|
| `infra/otel-demo-values.yaml` | Helm values for local Kubernetes (Honeycomb-ready) |
| `infra/otel-demo-values-aws.yaml` | Helm values for AWS EKS deployment |
| `infra/install-with-persistence.sh` | One-command installer with PostgreSQL persistence |
| `infra/postgres-persistent-setup.yaml` | PVC + ConfigMap for PostgreSQL with 2GB storage |
| `infra/postgres-otel-sidecar-patch.yaml` | OTel Collector sidecar for PostgreSQL metrics |
| `infra/INSTALL-FROM-SCRATCH.md` | Step-by-step Kubernetes installation guide |
| `infra/POSTGRESQL-LOGGING.md` | Enable PostgreSQL table lock logging |

**Key features:**
- Persistent PostgreSQL storage (data survives restarts)
- OpenTelemetry Collector sidecar for PostgreSQL metrics
- Pre-configured Honeycomb API key integration
- AWS-specific deployment configurations

**Upstream equivalent:** Basic Helm charts without persistence or sidecar configurations

---

### PostgreSQL Chaos Scenarios

**Added:** Database chaos testing infrastructure

**Location:** `infra/postgres-chaos/`

| Component | Purpose |
|-----------|---------|
| `postgres-chaos-scenarios.sh` | Interactive script to run DB chaos scenarios |
| `docs/` | Additional PostgreSQL chaos documentation |

**Scenarios supported:**
- Table locks (10-minute holds)
- Connection exhaustion
- Slow queries
- Combined failure modes

**Upstream equivalent:** None

---

### Documentation Simplification

**Changed:** Streamlined documentation to remove duplication and point to upstream

| File | Before | After | Change |
|------|--------|-------|--------|
| `README.md` | 171 lines | 35 lines (+appendix) | Points to upstream, focuses on fork-specific features |
| `CONTRIBUTING.md` | 313 lines | 18 lines | Points to upstream for main contributions |
| `infra/README.md` | 332 lines | 49 lines | Quick start only, detailed guides separate |
| `chaos-scenarios/README.md` | N/A | 58 lines | New consolidated index |

**Philosophy:** Single source of truth - point to upstream for general docs, maintain fork-specific content locally

**Upstream equivalent:** Full documentation maintained locally (171-line README, 313-line CONTRIBUTING, etc.)

---

### Custom Scripts & Helpers

**Added:** Utility scripts for deployment and testing

| Script | Purpose |
|--------|---------|
| `infra/install-with-persistence.sh` | One-command Kubernetes install with persistence |
| `infra/postgres-chaos/postgres-chaos-scenarios.sh` | Interactive chaos scenario runner |

**Upstream equivalent:** Manual Helm commands, no chaos testing infrastructure

---

### Monitoring & Observability

**Added:** 17 production-ready Honeycomb alerts + 3 SLO recommendations

**Alert categories:**
- Memory & resource exhaustion (5 alerts)
- Database performance (4 alerts)
- Application crashes (3 alerts)
- DNS failures (2 alerts)
- Rate limiting (2 alerts)
- Disk growth (1 alert)

**SLO recommendations:**
- Service availability (99.9% success rate)
- P95 latency (<500ms)
- Pod stability (<3 restarts/day)

**Upstream equivalent:** Example queries only, no production-ready alert configurations

---

### Configuration Defaults

**Changed:** Default configurations for Honeycomb integration

| Configuration | Fork Default | Upstream Default |
|--------------|--------------|------------------|
| Observability backend | Honeycomb (configurable) | Jaeger, Prometheus, Grafana |
| PostgreSQL storage | Persistent (2GB PVC) | Ephemeral |
| PostgreSQL memory | 300Mi (configurable) | Default Helm values |
| OTel Collector | Sidecar for PostgreSQL | Centralized only |

---

### File Organization

**Added:** New directory structure for chaos scenarios

```
chaos-scenarios/           (New in fork)
├── README.md
├── MEMORY-CHAOS.md
├── DATABASE-CHAOS.md
├── OBSERVABILITY-PATTERNS.md
├── frontend-flood-rate-limiting.md
├── filesystem-growth-crash-simple.md
└── istiod-crash-restart.md

infra/postgres-chaos/      (New in fork)
├── postgres-chaos-scenarios.sh
└── docs/
```

**Upstream equivalent:** No chaos-scenarios directory

---

### Removed Files

**Deleted from upstream:** Duplicate/legacy documentation files

- Removed WHY-* troubleshooting files (5 files) - consolidated into scenario guides
- Removed duplicate chaos index (ChaosTesting.md) - consolidated into README.md
- Archived old memory/alert docs to `infra/docs/archive/`

**Upstream equivalent:** Files present but may have different organization

---

### Key Differences Summary

| Aspect | This Fork | Upstream |
|--------|-----------|----------|
| **Chaos Engineering** | 7 comprehensive guides, 17 alerts | None |
| **PostgreSQL** | Persistent storage, sidecar metrics | Ephemeral, basic setup |
| **Observability Backend** | Honeycomb-focused | Jaeger/Prometheus/Grafana |
| **Documentation** | Streamlined, points to upstream | Full local docs |
| **Deployment** | One-command installer | Manual Helm |
| **Testing Infrastructure** | Database chaos scripts | None |
| **Alerts & SLOs** | 17 production-ready alerts, 3 SLOs | Example queries only |
| **Total Chaos Docs** | ~3,143 lines across 7 files | 0 lines |

---

### Maintenance Notes

**Syncing with upstream:**
- Core application code should be synced from upstream regularly
- Fork-specific content in `chaos-scenarios/` and `infra/` maintained separately
- Documentation simplified to minimize merge conflicts

**Fork-specific maintenance:**
- Chaos scenarios tested against each upstream release
- Alerts updated as new observability features are added
- Infrastructure configs verified with upstream Helm chart updates

---

**Last Updated:** 2025-11-19
**Upstream Version:** Latest as of fork date
**Fork Focus:** Chaos engineering, production observability, Honeycomb integration
