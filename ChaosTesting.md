# Chaos Testing Scenarios - Master Index

This document provides a comprehensive index of chaos engineering and failure scenario testing capabilities in the OpenTelemetry Demo.

## Table of Contents

- [Available Scenarios](#available-scenarios)
- [Scenario Coverage Matrix](#scenario-coverage-matrix)
- [Scenarios by Category](#scenarios-by-category)
- [Planned Scenarios](#planned-scenarios)
- [Quick Start Guide](#quick-start-guide)

---

## Available Scenarios

These scenarios are **ready to use** with complete guides and require **zero code changes**.

### Memory & Resource Exhaustion

| Scenario                        | Guide                                                                              | Method                                       | Observable Outcome                                    | Time to Failure                                                           |
| ------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------- |
| **Memory Spike / Sudden Crash** | [memory-tracking-spike-crash.md](chaos-scenarios/memory-tracking-spike-crash.md)   | `kafkaQueueProblems: 100-2000` + 10-50 users | OOM kill, container restart, alert triggers           | Configurable: slow (100-500), medium (500-1000), fast (2000) growth rates |
| **Gradual Memory Leak**         | [memory-leak-gradual-checkout.md](chaos-scenarios/memory-leak-gradual-checkout.md) | `kafkaQueueProblems: 200-300` + 25 users     | Heap pressure, predictable growth, trend analysis     | 10-20 minutes                                                             |
| **JVM GC Thrashing**            | [jvm-gc-thrashing-ad-service.md](chaos-scenarios/jvm-gc-thrashing-ad-service.md)   | `adManualGc: on` + 50 users                  | Stop-the-world pauses, latency spikes, zombie service | Continuous (10s cycles)                                                   |

### Disk & Storage Pressure

| Scenario                             | Guide                                                                                  | Method                     | Observable Outcome                                                 | Time to Failure |
| ------------------------------------ | -------------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------ | --------------- |
| **Filesystem Growth / Disk Full**    | [filesystem-growth-crash-simple.md](chaos-scenarios/filesystem-growth-crash-simple.md) | Error flags + 50 users     | OpenSearch disk grows 900MB → 4-5GB, cluster yellow/red            | 2-3 hours       |
| **Postgres IOPS Pressure (Organic)** | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md)       | High traffic: 200 users    | Database growth 10MB → 200MB+, disk I/O pressure, cache monitoring | 2-4 hours       |
| **Postgres Cache Chaos Demo**        | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md) (Option 4) | Reduce cache: 128MB → 32MB | Immediate cache degradation, 98% → 70-85% hit ratio                | Immediate       |

**Setup Guide:**

- [postgres-seed-for-iops.md](chaos-scenarios/postgres-seed-for-iops.md) - Optional: Pre-seed 150K orders for instant IOPS demo

### Infrastructure Failures

| Scenario                   | Guide                                                                      | Method                                                                          | Observable Outcome                                                                        | Time to Failure                                                     |
| -------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| **DNS Resolution Failure** | [dns-resolution-failure.md](chaos-scenarios/dns-resolution-failure.md)     | Scale CoreDNS to 0 replicas                                                     | All service calls fail with "no such host", traces have no child spans                    | Variable: immediate to 5 min (depends on service runtime DNS cache) |
| **DNS Capacity Issues**    | [dns-insufficient-coredns.md](chaos-scenarios/dns-insufficient-coredns.md) | Scale CoreDNS UP (10 replicas), populate cache, scale DOWN to 2 (80% reduction) | Mixed success/failure (50-80%), variable latency (fast/slow/timeout), CoreDNS CPU 95-100% | Gradual: 3-10 min as cache expires                                  |

---

## Scenario Coverage Matrix

Comprehensive mapping of chaos testing scenarios to implementation status and observability:

| Scenario Type                         | Description                            | Method                                                                         | Observable Signals                                                                      | Status                             | Guide                                                                                                                                                                    |
| ------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Disk Full / I/O Latency**           | Fill disk with data                    | Postgres: 200 users / OpenSearch: error flags                                  | Disk usage metrics, I/O wait time, query latency, cache hit ratio drop                  | ✅ Available                       | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md), [filesystem-growth-crash-simple.md](chaos-scenarios/filesystem-growth-crash-simple.md) |
| **Cache Degradation (Chaos)**         | Undersized cache causing IOPS pressure | Reduce PostgreSQL `shared_buffers` 128MB → 32MB                                | Cache hit ratio drop (98% → 70-85%), 10x disk reads, query latency                      | ✅ Available                       | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md) (Option 4)                                                                                               |
| **CPU / Memory Spikes or Saturation** | Drive CPU or memory to 100%            | `kafkaQueueProblems: 100-2000` (adjustable) + 10-50 users                      | CPU/memory metrics, OOM kill, pod restart, correlated process, MTTR                     | ✅ Available                       | [memory-tracking-spike-crash.md](chaos-scenarios/memory-tracking-spike-crash.md)                                                                                         |
| **CPU Saturation (standalone)**       | Drive CPU to 100% independently        | `adHighCpu: on` flag                                                           | CPU utilization metrics, latency spikes, correlated process                             | ⚠️ Flag exists, needs guide        | Flag available in `demo.flagd.json`                                                                                                                                      |
| **Memory Leak / Heap Pressure**       | Gradual memory allocation              | `kafkaQueueProblems: 200-300` + moderate load                                  | Heap trend, GC pauses, predictable failure                                              | ✅ Available                       | [memory-leak-gradual-checkout.md](chaos-scenarios/memory-leak-gradual-checkout.md)                                                                                       |
| **DNS Problem**                       | DNS resolution failure                 | Stop CoreDNS / Scale to 0 replicas                                             | DNS latency isolated as root cause, service timeouts, "no such host" errors             | ✅ Available                       | [dns-resolution-failure.md](chaos-scenarios/dns-resolution-failure.md)                                                                                                   |
| **Insufficient CoreDNS**              | Reduce CoreDNS capacity                | Scale CoreDNS up (10 replicas), populate cache, then scale down (1-2 replicas) | DNS lookup delays, intermittent failures, mixed success/failure, CoreDNS CPU saturation | ✅ Available                       | [dns-insufficient-coredns.md](chaos-scenarios/dns-insufficient-coredns.md)                                                                                               |
| **Storage I/O Constraint**            | IOPS quota exhaustion                  | High write volume to Postgres                                                  | `blk_read_time`, `blk_write_time`, query latency, cache metrics                         | ✅ Available                       | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md)                                                                                         |
| **Application Crash**                 | Kill process/pod                       | Manual pod delete or `adFailure`, `cartFailure`, `paymentFailure` flags        | Alert triggers, restart events, trace ends abruptly, MTTR                               | ⚠️ Flags exist, needs guide        | Flags available, manual pod kill works                                                                                                                                   |
| **Service Degradation**               | Slow responses without crash           | `imageSlowLoad`, `paymentFailure: 50%`                                         | Latency increase, partial failures, SLO burn                                            | ⚠️ Flags exist, needs guide        | Flags available in `demo.flagd.json`                                                                                                                                     |
| **Kafka Queue Overload**              | Message backlog and lag                | `kafkaQueueProblems: 100` + high load                                          | Consumer lag, processing delays, queue depth                                            | ⚠️ Implicit in other scenarios     | Documented in memory scenarios                                                                                                                                           |
| **Network Latency**                   | Slow network between services          | Not implemented                                                                | Trace shows network time, service-to-service latency                                    | 🔴 Not implemented                 | Requires network policy or sidecar                                                                                                                                       |
| **Database Connection Exhaustion**    | Max connections reached                | High concurrency + sustained load                                              | Connection pool errors, timeouts                                                        | ⚠️ Possible with Postgres scenario | Achievable with postgres-disk-iops-pressure                                                                                                                              |

**Legend:**

- ✅ **Available** - Complete guide exists, ready to use
- ⚠️ **Partial** - Flag/capability exists, needs documentation
- 🔴 **Not Implemented** - Requires code/config changes

---

## Scenarios by Category

### 1. Resource Exhaustion

#### Memory

| Scenario            | Target Service    | Failure Pattern                 | Guide                                                                              |
| ------------------- | ----------------- | ------------------------------- | ---------------------------------------------------------------------------------- |
| Sudden Memory Spike | Checkout (Go)     | Exponential growth → OOM crash  | [memory-tracking-spike-crash.md](chaos-scenarios/memory-tracking-spike-crash.md)   |
| Gradual Memory Leak | Checkout (Go)     | Linear growth → predictable OOM | [memory-leak-gradual-checkout.md](chaos-scenarios/memory-leak-gradual-checkout.md) |
| JVM Heap Pressure   | Ad Service (Java) | GC thrashing → zombie service   | [jvm-gc-thrashing-ad-service.md](chaos-scenarios/jvm-gc-thrashing-ad-service.md)   |

**Observability:**

- Container memory metrics (working set, limit utilization)
- Heap allocation and GC metrics
- OOM events and restart counts
- Latency correlation with memory pressure

#### CPU

| Scenario       | Target Service    | Method          | Status                      |
| -------------- | ----------------- | --------------- | --------------------------- |
| CPU Saturation | Ad Service (Java) | `adHighCpu: on` | ⚠️ Flag exists, needs guide |

**Observability (expected):**

- CPU utilization at 100%
- Process CPU time breakdown
- Latency spikes correlated with CPU
- Throttling events

#### Disk & Storage

| Scenario                  | Target     | Failure Pattern                                   | Guide                                                                                  |
| ------------------------- | ---------- | ------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Log Storage Growth        | OpenSearch | Accumulation → disk full → cluster degradation    | [filesystem-growth-crash-simple.md](chaos-scenarios/filesystem-growth-crash-simple.md) |
| Database Disk Growth      | Postgres   | Transaction volume → disk exhaustion              | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md)       |
| IOPS Pressure (Organic)   | Postgres   | Sustained writes → I/O saturation → latency       | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md)       |
| Cache Degradation (Chaos) | Postgres   | Undersized cache → excessive disk reads → latency | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md) (Option 4)             |

**Observability:**

- Disk usage metrics (absolute and percentage)
- I/O wait time and throughput
- Database cache hit ratio degradation
- Query latency increase

### 2. Service Failures

#### Crashes & Restarts

| Scenario      | Target Service  | Method                   | Status              |
| ------------- | --------------- | ------------------------ | ------------------- |
| Service Crash | Ad Service      | `adFailure: on`          | ⚠️ Flag exists      |
| Service Crash | Cart Service    | `cartFailure: on`        | ⚠️ Flag exists      |
| Service Crash | Payment Service | `paymentUnreachable: on` | ⚠️ Flag exists      |
| Pod Kill      | Any service     | `kubectl delete pod`     | ✅ Manual operation |

**Observability (expected):**

- Service down alerts
- Pod/container restart events
- MTTR calculation
- Traces ending abruptly
- Fatal log entries

#### Partial Failures

| Scenario              | Target Service         | Method                           | Status         |
| --------------------- | ---------------------- | -------------------------------- | -------------- |
| Intermittent Failures | Payment Service        | `paymentFailure: 10-100%`        | ⚠️ Flag exists |
| Slow Responses        | Image Provider         | `imageSlowLoad: 5sec/10sec`      | ⚠️ Flag exists |
| Cache Failures        | Recommendation Service | `recommendationCacheFailure: on` | ⚠️ Flag exists |

**Observability (expected):**

- Partial error rate (n% failures)
- Latency increase without crash
- SLO burn rate
- Circuit breaker activation

### 3. Infrastructure Issues

#### Queue & Messaging

| Scenario         | Target             | Method                     | Status                          |
| ---------------- | ------------------ | -------------------------- | ------------------------------- |
| Kafka Lag Spike  | Kafka + Accounting | `kafkaQueueProblems: 100`  | ⚠️ Implicit in memory scenarios |
| Message Overload | Kafka Topic        | `kafkaQueueProblems: 2000` | ✅ Documented in memory guides  |

**Observability:**

- Consumer lag metrics
- Queue depth
- Processing delays
- Backpressure effects

#### Network & DNS

| Scenario                                  | Method                                                                  | Status             | Guide                                                                      |
| ----------------------------------------- | ----------------------------------------------------------------------- | ------------------ | -------------------------------------------------------------------------- |
| DNS Resolution Failure                    | Stop CoreDNS (scale to 0)                                               | ✅ Available       | [dns-resolution-failure.md](chaos-scenarios/dns-resolution-failure.md)     |
| DNS Capacity Issue / Insufficient CoreDNS | Scale CoreDNS up (10), populate cache, scale down (1-2) - 80% reduction | ✅ Available       | [dns-insufficient-coredns.md](chaos-scenarios/dns-insufficient-coredns.md) |
| Network Latency                           | Chaos mesh / network policy                                             | 🔴 Not implemented | Requires additional tooling                                                |

**Observability:**

- **Complete DNS Failure:** "no such host" errors, 100% failure rate, uniform timeout (~5s), traces with no child spans
- **DNS Capacity Issues:** Mixed success/failure (50-80%), variable latency (fast cached → slow queued → timeout), CoreDNS CPU at 95-100%, three distinct latency bands in heatmap
- Error messages without IP addresses (DNS never resolved)

### 4. Database Issues

**Note:** See [verify-postgres.md](infra/verify-postgres.md) for comprehensive verification that Postgres is running and receiving data.

| Scenario                       | Database | Method                                         | Guide                                                                                          |
| ------------------------------ | -------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Disk Growth & IOPS (Organic)   | Postgres | High traffic: 200 users → 200MB+ DB            | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md) ✅ **Tested** |
| Cache Degradation (Chaos Demo) | Postgres | Reduce `shared_buffers` 128MB → 32MB           | [postgres-disk-iops-pressure.md](chaos-scenarios/postgres-disk-iops-pressure.md) (Option 4) ✅ **Tested**       |
| Pre-seeded IOPS Demo           | Postgres | Load 150K orders (~200MB) for instant pressure | [postgres-seed-for-iops.md](chaos-scenarios/postgres-seed-for-iops.md) ✅ **Tested**           |
| Connection Exhaustion          | Postgres | High concurrency                               | ⚠️ Achievable with high user load (not yet documented)                                         |

**Observability:**

- Database size and table growth
- I/O metrics (read/write time)
- Cache hit ratio
- Connection pool utilization
- Query latency trends

---

## Planned Scenarios

These scenarios require additional implementation:

### High Priority

| Scenario                              | Implementation Needed                                               | Estimated Complexity |
| ------------------------------------- | ------------------------------------------------------------------- | -------------------- |
| **Application Crash Guide**           | Documentation only (flags exist: `adFailure`, `cartFailure`, etc.)  | Low - 2 hours        |
| **Service Degradation Guide**         | Documentation only (flags exist: `paymentFailure`, `imageSlowLoad`) | Medium - 3 hours     |
| **CPU Saturation (standalone) Guide** | Documentation only (flag exists: `adHighCpu`)                       | Low - 1 hour         |

### Medium Priority

| Scenario                                 | Implementation Needed                                         | Estimated Complexity               |
| ---------------------------------------- | ------------------------------------------------------------- | ---------------------------------- |
| **Network Latency**                      | Chaos Mesh or Istio fault injection                           | High - requires additional tooling |
| **Connection Pool Exhaustion**           | Enhanced load testing against Postgres                        | Medium - extend existing scenario  |
| **DNS Capacity Issue (formalize guide)** | Document the scale-up-then-down technique as separate section | Low - technique already exists     |

### Low Priority

| Scenario                   | Implementation Needed              | Estimated Complexity           |
| -------------------------- | ---------------------------------- | ------------------------------ |
| **Certificate Expiration** | Mock cert expiration mechanism     | High - requires TLS setup      |
| **Rate Limiting**          | Add rate limiter to services       | Medium - code changes required |
| **Cascading Failures**     | Orchestrated multi-service failure | Medium - complex scenario      |

---

## Quick Start Guide

### 1. Choose Your Scenario

**For Instant Impact (immediate):**

- [Postgres Cache Chaos Demo](chaos-scenarios/postgres-disk-iops-pressure.md) (Option 4) - Immediate cache degradation (98% → 70-85% hit ratio)
- [JVM GC Thrashing](chaos-scenarios/jvm-gc-thrashing-ad-service.md) - Immediate cyclical degradation

**For Rapid Testing (configurable timing):**

- [Memory Spike](chaos-scenarios/memory-tracking-spike-crash.md) - Adjustable growth rate: slow (100-500), medium (500-1000), fast (2000)

**For Gradual Observation (10-30 minutes):**

- [Gradual Memory Leak](chaos-scenarios/memory-leak-gradual-checkout.md) - 10-20 minutes to OOM

**For Long-Term Trends (hours):**

- [Filesystem Growth](chaos-scenarios/filesystem-growth-crash-simple.md) - 2-3 hours for significant growth
- [Postgres IOPS (Organic)](chaos-scenarios/postgres-disk-iops-pressure.md) - 2-4 hours for I/O pressure with 200 users

### 2. Prerequisites

All scenarios require:

- ✅ OpenTelemetry Demo running
- ✅ Telemetry configured to send to Honeycomb
- ✅ Access to FlagD UI (http://localhost:4000)
- ✅ Access to Locust UI (http://localhost:8089)

### 3. Common Workflow

**Step 1:** Read the scenario guide
**Step 2:** Enable feature flag in FlagD UI
**Step 3:** Generate load in Locust
**Step 4:** Monitor in Honeycomb
**Step 5:** Clean up (disable flag, stop load)

### 4. Flag Quick Reference

| Flag                         | Effect                  | Scenarios Using It                       |
| ---------------------------- | ----------------------- | ---------------------------------------- |
| `kafkaQueueProblems`         | Kafka message flood     | Memory spike, memory leak, Postgres disk |
| `adManualGc`                 | JVM GC thrashing        | JVM GC scenario                          |
| `adHighCpu`                  | CPU saturation          | (needs guide)                            |
| `adFailure`                  | Ad service crash        | (needs guide)                            |
| `cartFailure`                | Cart service crash      | (needs guide)                            |
| `paymentFailure`             | Payment errors (0-100%) | (needs guide)                            |
| `paymentUnreachable`         | Payment service down    | (needs guide)                            |
| `imageSlowLoad`              | Slow image loading      | (needs guide)                            |
| `loadGeneratorFloodHomepage` | Frontend overload       | (needs guide)                            |
| `recommendationCacheFailure` | Cache failures          | (needs guide)                            |
| `productCatalogFailure`      | Product errors          | (needs guide)                            |

---

## Observability Patterns

### Metrics to Monitor

**Resource Metrics:**

- `k8s.pod.memory.working_set` - Current memory usage
- `k8s.pod.memory_limit_utilization` - Memory as % of limit
- `k8s.pod.cpu_utilization` - CPU usage
- `k8s.pod.ephemeral-storage.used` - Disk usage

**Application Metrics:**

- `jvm.memory.used` - JVM heap usage (Java services)
- `jvm.gc.duration` - Garbage collection time
- `process.runtime.go.mem.heap_alloc` - Go heap allocation
- `process.runtime.go.goroutines` - Goroutine count

**Database Metrics:**

- `db.io.read_bytes`, `db.io.write_bytes` - Database I/O
- Cache hit ratio (from `pg_stat_database`)
- Table sizes and row counts
- Connection pool utilization

**Service Metrics:**

- Request rate (`COUNT`)
- Latency percentiles (`P50`, `P95`, `P99`)
- Error rate (`otel.status_code`)
- Trace completion vs. abandonment

### Honeycomb Query Patterns

**Resource Pressure:**

```
WHERE k8s.pod.name STARTS_WITH <service>
VISUALIZE MAX(<metric>)
GROUP BY time(30s)
```

**Service Degradation:**

```
WHERE service.name = <service>
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

**Error Analysis:**

```
WHERE service.name = <service>
VISUALIZE COUNT
GROUP BY otel.status_code
```

**Trace Investigation:**

```
WHERE service.name = <service> AND duration_ms > <threshold>
VISUALIZE TRACES
ORDER BY duration_ms DESC
```

---

## Contributing New Scenarios

Want to add a new chaos testing scenario? Follow these guidelines:

### 1. Scenario Documentation Template

Each scenario guide should include:

- **Overview** - Use case summary
- **Prerequisites** - Required setup
- **How It Works** - Technical explanation
- **Execution Steps** - Step-by-step instructions for Kubernetes
- **Monitoring Queries** - 10+ Honeycomb queries
- **Dashboard Configuration** - Multi-panel setup
- **Expected Timeline** - Time-based progression
- **Alert Configuration** - Alerting thresholds
- **Trace Correlation** - Example trace analysis
- **Troubleshooting** - Common issues
- **Cleanup** - How to reset

### 2. Naming Convention

- Use lowercase with hyphens: `scenario-name-target-service.md`
- Be descriptive: `postgres-disk-iops-pressure.md` not `db-test.md`
- Include target service when applicable

### 3. Update This Index

When adding a scenario:

1. Add row to **Scenario Coverage Matrix**
2. Add to appropriate **Scenarios by Category** section
3. Update **Flag Quick Reference** if using new flags
4. Update main [README.md](README.md) scenario list

### 4. Testing Checklist

Before submitting:

- [ ] Tested on Kubernetes
- [ ] Honeycomb queries verified
- [ ] Screenshots captured (optional)
- [ ] Timeline documented with actual results
- [ ] Cleanup steps verified

---

## Support & Feedback

- **OpenTelemetry Demo Issues:** https://github.com/open-telemetry/opentelemetry-demo/issues
- **Honeycomb Documentation:** https://docs.honeycomb.io
- **Slack:** [CNCF Slack #otel-demo](https://cloud-native.slack.com/archives/C03B4CWV4DA)

---

## References

- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [Chaos Engineering Principles](https://principlesofchaos.org/)
- [Site Reliability Engineering (SRE)](https://sre.google/)
- [Honeycomb Observability](https://www.honeycomb.io/blog)

---

**Last Updated:** 2025-10-30

**Scenario Count:**

- ✅ Available: 10 scenarios
  - Memory: Memory spike, Gradual leak, JVM GC
  - Disk/Storage: Filesystem growth, Postgres IOPS (organic), Postgres cache chaos, Postgres pre-seed
  - Infrastructure: DNS failure, DNS capacity issues
- ⚠️ Partial: 5 scenarios (flags exist for crash/degradation guides)
- 🔴 Not Implemented: 1 scenario (network latency - requires additional tooling)
