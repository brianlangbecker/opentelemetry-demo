# Memory & Resource Exhaustion Chaos Scenarios

Comprehensive guide for demonstrating memory exhaustion, OOM crashes, and JVM garbage collection issues.

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Scenario 1: Memory Spike / Sudden Crash](#scenario-1-memory-spike--sudden-crash)
3. [Scenario 2: Gradual Memory Leak](#scenario-2-gradual-memory-leak)
4. [Scenario 3: JVM GC Thrashing](#scenario-3-jvm-gc-thrashing)
5. [Monitoring & Alerts](#monitoring--alerts)

---

## Quick Reference

| Scenario | Target | Flag | Flag Value | Users | Pattern | Time to Failure |
|----------|--------|------|------------|-------|---------|-----------------|
| **Memory Spike** | Checkout (Go) | `kafkaQueueProblems` | 2000 | 50 | Sudden crash | 60-90 seconds |
| **Memory Spike (Controlled)** | Checkout only | `kafkaQueueProblems` | 200-500 | 25 | Controlled crash | 2-5 minutes |
| **Gradual Memory Leak** | Checkout (Go) | `kafkaQueueProblems` | 200-300 | 25 | Linear growth | 10-20 minutes |
| **JVM GC Thrashing** | Ad Service (Java) | `adManualGc` | on | 50 | Cyclical degradation | Continuous (no crash) |

**Key Difference:**
- **Spike:** Fast exponential growth → OOM crash
- **Leak:** Slow linear growth → OOM crash
- **GC Thrashing:** Cyclical performance degradation → zombie service (no crash)

---

## Scenario 1: Memory Spike / Sudden Crash

Demonstrate fast memory exhaustion leading to OOM crash in the checkout service.

### Target Services

**Primary:** `checkout` (Go) - 20Mi memory limit
**Secondary:** `accounting` (C#) - 120Mi memory limit

> ⚠️ **WARNING: Cascading Failures**
>
> **High flag values (2000) crash BOTH services:**
> - Checkout creates N Kafka messages (N = flag value)
> - Accounting tries to consume ALL messages
> - With 2000 messages/order, accounting OOMs in seconds
>
> **Use 200-500 for checkout-only crashes**
> **Use 2000 to demonstrate cascading failures**

---

### How It Works

**Checkout Service (Primary):**
1. User completes checkout
2. Feature flag triggers N goroutines (N = flag value)
3. Each goroutine sends Kafka messages
4. Memory grows: ~8Mi → 20Mi in seconds
5. OOM Kill when limit exceeded
6. Container restart

**Accounting Service (Cascading with High Values):**
1. Kafka topic floods with messages (2000 per order)
2. Accounting (120Mi limit) consumes messages
3. Memory pressure from message queue
4. OOM Kill
5. Both services crash

**Growth Rate:**
- Flag 2000 + 50 users: **60-90 seconds** (fast crash)
- Flag 500 + 25 users: **2-5 minutes** (controlled)
- Flag 200 + 25 users: **5-10 minutes** (slower)

---

### Execution Steps

**1. Enable Feature Flag:**
```
http://localhost:4000 (FlagD UI)
Set kafkaQueueProblems = 2000
```

**2. Start Load Test:**
```
http://localhost:8089 (Locust)
Users: 50, Spawn rate: 5
```

**3. Monitor Pods:**
```bash
watch 'kubectl get pods -n otel-demo | grep -E "checkout|accounting"'
```

**Expected:** Both pods restart within 60-90 seconds

---

### Observable Patterns

#### Memory Growth (Checkout)

```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(10s)
```

**Pattern:** Rapid climb from 8Mi → 20Mi in 60-90s

#### Memory Limit Utilization

```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.pod.memory_limit_utilization)
GROUP BY time(10s)
```

**Pattern:** 40% → 100% in <2 minutes

#### Restart Count

```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY time(30s)
```

**Shows:** Restart count incrementing

#### OOM Events (k8s-events dataset)

```
WHERE namespace = "otel-demo"
  AND k8s.pod.name STARTS_WITH "checkout"
  AND k8s.container.last_terminated.reason = "OOMKilled"
VISUALIZE k8s.event.reason, k8s.container.last_terminated.exit_code
```

**Expected:** Exit code 137 (OOM kill)

---

### Cleanup

```
# Stop load test (Locust UI)
# Disable flag (FlagD UI): kafkaQueueProblems = off
```

---

## Scenario 2: Gradual Memory Leak

Demonstrate slow memory leak with heap pressure building over time.

### Target Service

`checkout` (Go) - 20Mi memory limit

**Pattern:** Linear/gradual growth (not sudden spike) - simulates real-world production memory leaks.

---

### How It Works

1. User completes checkout
2. Feature flag triggers N goroutines (N = 200-300)
3. Gradual memory accumulation with moderate load
4. GC pressure builds over time
5. Latency degrades (GC pauses)
6. Eventually OOM after 10-20 minutes
7. Container restart

**Growth Timeline:**
- **0-5 min:** 8Mi → 12Mi (60% utilization)
- **5-10 min:** 12Mi → 16Mi (80% utilization), frequent GC
- **10-15 min:** 16Mi → 18Mi (90% utilization), latency impact
- **15-20 min:** 20Mi limit reached, OOM kill

---

### Flag Values and Growth Rates

| Flag Value | Users | Pattern | Time to OOM |
|------------|-------|---------|-------------|
| 100 | 20 | Very gradual | 30-40 minutes |
| 200 | 25 | Gradual | 20-30 minutes |
| 300 | 30 | Moderate | 10-20 minutes |
| 500 | 30 | Noticeable | 5-10 minutes |

**Recommendation:** Use **200-300** with **25-30 users**

---

### Execution Steps

**1. Enable Feature Flag:**
```
http://localhost:4000 (FlagD UI)
Set kafkaQueueProblems = 200
```

**2. Start Moderate Load:**
```
http://localhost:8089 (Locust)
Users: 25, Spawn rate: 5
```

**3. Monitor Over Time:**
```bash
kubectl top pod -n otel-demo | grep checkout
# Watch memory climb gradually
```

---

### Observable Patterns

#### Gradual Memory Trend

```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(1m)
```

**Pattern:** Linear climb over 10-20 minutes

#### Heap Allocation (Go)

```
WHERE service.name = "checkout"
  AND process.runtime.go.mem.heap_alloc EXISTS
VISUALIZE MAX(process.runtime.go.mem.heap_alloc)
GROUP BY time(1m)
```

**Shows:** Heap growth correlation

#### Goroutine Count

```
WHERE service.name = "checkout"
  AND process.runtime.go.goroutines EXISTS
VISUALIZE MAX(process.runtime.go.goroutines)
GROUP BY time(1m)
```

**Shows:** Goroutine accumulation

#### Latency Degradation (GC Impact)

```
WHERE service.name = "checkout"
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

**Pattern:** P99 latency increases as GC pressure builds

---

### Cleanup

```
# Stop load test (Locust UI)
# Disable flag (FlagD UI): kafkaQueueProblems = off
```

---

## Scenario 3: JVM GC Thrashing

Demonstrate JVM garbage collection storms and stop-the-world pauses without crashing (zombie service pattern).

### Target Service

`ad` (Java) - 300Mi memory limit

**Pattern:** Cyclical GC storms → latency spikes → performance degradation (service stays alive but becomes periodically unresponsive)

---

### How It Works

When `adManualGc` flag is enabled, each ad request triggers aggressive GC:

1. Heap filled to 90% capacity
2. Creates 500,000 objects with expensive finalizers
3. Triggers 10 consecutive full GC cycles
4. Each GC causes "stop-the-world" pauses
5. Process repeats every 10 seconds
6. Dramatic latency spikes and degraded performance

**Key Point:** Service doesn't crash - it becomes a "zombie" with periodic unresponsiveness.

---

### Execution Steps

**1. Check Baseline:**
```bash
kubectl top pod -n otel-demo | grep ad
# Normal: ~50-100Mi memory
```

**2. Enable GC Thrashing Flag:**
```
http://localhost:4000 (FlagD UI)
Set adManualGc = on
```

**3. Start Load Test:**
```
http://localhost:8089 (Locust)
Users: 50, Spawn rate: 5
```

**4. Observe GC Cycles:**
```bash
kubectl logs -n otel-demo deployment/ad --tail=50 | grep -i "gc\|garbage"
```

---

### Observable Patterns

#### Latency Spikes (Cyclical Pattern)

```
WHERE service.name = "ad"
VISUALIZE P95(duration_ms), P99(duration_ms), MAX(duration_ms)
GROUP BY time(30s)
```

**Pattern:** Cyclical spikes every 10 seconds (GC cycles)

#### Latency Heatmap (Shows GC Pauses)

```
WHERE service.name = "ad"
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
```

**Pattern:** Two bands - fast (no GC) and slow (during GC)

#### JVM Heap Usage

```
WHERE service.name = "ad"
  AND jvm.memory.used EXISTS
VISUALIZE MAX(jvm.memory.used)
GROUP BY jvm.memory.type, time(30s)
```

**Pattern:** Heap oscillation (fill → GC → fill → GC)

#### JVM GC Duration

```
WHERE service.name = "ad"
  AND jvm.gc.duration EXISTS
VISUALIZE SUM(RATE(jvm.gc.duration))
GROUP BY jvm.gc.name, time(30s)
```

**Pattern:** Frequent, expensive GC cycles

#### Request Success Rate

```
WHERE service.name = "ad"
VISUALIZE (COUNT WHERE otel.status_code = OK) / COUNT
GROUP BY time(1m)
```

**Pattern:** Periodic drops during GC pauses

---

### Key Indicators

**GC Thrashing Patterns:**
- ✅ Cyclical latency spikes (every 10s)
- ✅ Two-band latency distribution (fast/slow)
- ✅ High JVM GC duration
- ✅ Service stays alive (no crashes)
- ✅ Heap oscillation (sawtooth pattern)
- ✅ CPU spikes during GC

**NOT GC Thrashing:**
- ❌ Consistent latency (no cyclical pattern)
- ❌ Service crashes/restarts
- ❌ Linear memory growth without oscillation

---

### Cleanup

```
# Stop load test (Locust UI)
# Disable flag (FlagD UI): adManualGc = off
```

---

## Monitoring & Alerts

### Alert 1: Memory Limit Approaching

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.pod.memory_limit_utilization)
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** MAX(k8s.pod.memory_limit_utilization) > 0.9
- **Duration:** For at least 2 minutes
- **Severity:** WARNING

**Notification:**
```
⚠️ Memory Limit Approaching

Pod: {{k8s.pod.name}}
Memory Utilization: {{MAX(k8s.pod.memory_limit_utilization)}}%

Action: Investigate memory growth before OOM kill
```

---

### Alert 2: OOM Kill Detected

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.container.last_terminated.reason = "OOMKilled"
VISUALIZE COUNT
GROUP BY k8s.pod.name, time(5m)
```

**Trigger:**
- **Threshold:** COUNT > 0
- **Severity:** CRITICAL

**Notification:**
```
🔴 Pod OOM Kill Detected

Pod: {{k8s.pod.name}}
Exit Code: 137
Reason: Out of Memory

Action: Check memory limits and usage patterns
```

---

### Alert 3: High Restart Rate

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY time(10m)
```

**Trigger:**
- **Threshold:** Increase > 3 restarts in 10 minutes
- **Severity:** WARNING

---

### Alert 4: GC Thrashing Detected

**Query:**
```
WHERE service.name = "ad"
  AND jvm.gc.duration EXISTS
VISUALIZE SUM(RATE(jvm.gc.duration))
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** SUM(RATE(jvm.gc.duration)) > 500ms per minute
- **Severity:** WARNING

**Notification:**
```
⚠️ JVM GC Thrashing Detected

Service: ad
GC Duration: {{SUM(RATE(jvm.gc.duration))}}ms/min

Pattern: Frequent garbage collection cycles
Action: Check heap size and memory pressure
```

---

### Alert 5: Latency Degradation (GC Impact)

**Query:**
```
WHERE service.name = "checkout"
VISUALIZE P99(duration_ms)
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** P99(duration_ms) > 1000ms AND P50(duration_ms) < 200ms
- **Severity:** WARNING

**Why:** P99 high + P50 low indicates periodic slowness (GC pauses)

---

## Comparison Matrix

| Aspect | Memory Spike | Gradual Leak | JVM GC Thrashing |
|--------|--------------|--------------|------------------|
| **Language** | Go | Go | Java |
| **Growth** | Exponential | Linear | Oscillating |
| **Time to impact** | 60-90s | 10-20m | Continuous |
| **Outcome** | OOM crash | OOM crash | Performance degradation |
| **Restart** | Yes | Yes | No |
| **Latency pattern** | Increasing until crash | Gradual increase | Cyclical spikes |
| **Detection** | Easy (fast crash) | Moderate (trending) | Hard (no crash) |
| **Production analog** | Memory leak bug | Slow leak/cache growth | Undersized heap |

---

## Production Scenarios Simulated

### Memory Spike
- Connection leak with traffic spike
- Unbounded cache during peak load
- Message queue flood
- Cascading failures across services

### Gradual Memory Leak
- Slow connection leaks
- Growing caches without eviction
- Event listener accumulation
- Object retention from closures

### JVM GC Thrashing
- Undersized JVM heap for workload
- Too many short-lived objects
- Expensive finalizers
- Old generation pressure

---

## Key Takeaways

### Detection Patterns

**Memory Spike:**
- ✅ Fast memory growth (seconds to minutes)
- ✅ Sharp increase in utilization
- ✅ Quick OOM kill
- ✅ Possible cascading failures

**Gradual Leak:**
- ✅ Linear memory growth over time
- ✅ Increasing GC activity
- ✅ Latency correlation with memory
- ✅ Predictable failure timeline

**GC Thrashing:**
- ✅ Cyclical latency spikes
- ✅ Two-band latency distribution
- ✅ High GC duration
- ✅ Service alive but degraded
- ✅ Sawtooth heap pattern

### Alert Strategy

**CRITICAL:** OOM kills, high restart rate
**WARNING:** Memory approaching limit, GC thrashing, latency degradation

### Monitoring Best Practices

1. Track memory utilization % (not just absolute values)
2. Monitor restart counts and OOM events
3. Correlate latency with memory/GC metrics
4. Use heatmaps to identify cyclical patterns
5. Alert on trends, not just thresholds

---

## Related Scenarios

- [OBSERVABILITY-PATTERNS.md](OBSERVABILITY-PATTERNS.md) - Application crash observability and alerting
- [DATABASE-CHAOS.md](DATABASE-CHAOS.md) - Database resource exhaustion

---

**Last Updated:** 2025-11
**Status:** Production-ready chaos scenarios
