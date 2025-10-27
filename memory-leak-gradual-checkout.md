# Gradual Memory Leak / Heap Pressure - Checkout Service

## Overview

This guide demonstrates how to observe a **gradual memory leak** with heap pressure building over time using the OpenTelemetry Demo's checkout service (Go), with telemetry sent to Honeycomb for analysis.

**Note:** This uses the same `kafkaQueueProblems` flag as the spike scenario, but with **lower values and moderate load** to create a gradual growth pattern instead of sudden crash.

### Use Case Summary

- **Target Service:** `checkout` (Go microservice)
- **Memory Limit:** 20Mi
- **Trigger Mechanism:** Feature flag (`kafkaQueueProblems`) + Moderate load
- **Observable Outcome:** Gradual memory growth → GC pressure → Eventually OOM Kill
- **Pattern:** Linear/gradual growth (not sudden spike)
- **Monitoring:** Honeycomb UI for heap trends, GC activity, and correlation

---

## Related Scenarios Using `kafkaQueueProblems` Flag

The same feature flag creates different failure modes depending on configuration:

| Scenario | Target | Flag Value | Users | Observable Outcome |
|----------|--------|------------|-------|-------------------|
| **[Memory Spike](memory-tracking-spike-crash.md)** | Checkout service (Go) | 2000 | 50 | Fast OOM crash in 60-90s |
| **[Gradual Memory Leak](memory-leak-gradual-checkout.md)** | Checkout service (Go) | 200-300 | 25 | Gradual OOM in 10-20m (this guide) |
| **[Postgres Disk/IOPS](postgres-disk-iops-pressure.md)** | Postgres database | 2000 | 50 | Disk growth + I/O pressure |

**Key Difference:** This guide demonstrates **slow, gradual memory leak** that mimics real-world production memory issues - harder to detect but easier to predict once identified.

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- Kubernetes cluster OR Docker Compose
- Access to Honeycomb UI
- FlagD UI accessible

---

## Flag Values and Growth Rates

| Flag Value | Load | Pattern | Use Case |
|------------|------|---------|----------|
| `100` | 20 users | Very gradual growth | Slow, extended observation |
| `200` | 25 users | Gradual growth | Observable trend over time |
| `300` | 30 users | Moderate growth | Clear pattern, reasonable timeframe |
| `500` | 30 users | Noticeable growth | Faster pattern demonstration |
| `2000` | 50 users | Immediate spike | Sudden crash (not gradual leak) |

**Recommendation:** Use **200-300** with **25-30 users** for observable gradual growth.

---

## How It Works

When `kafkaQueueProblems` flag is enabled with moderate values:

1. **User completes checkout** in the demo application
2. **Checkout service** receives the order request
3. **Feature flag triggered:** Service spawns N goroutines (where N = flag value, e.g., 300)
4. **Each goroutine** sends Kafka messages at a moderate rate
5. **Gradual memory accumulation:** With 300 goroutines and 25 users, memory grows slowly from ~8Mi
6. **GC pressure builds:** Garbage collector runs more frequently as memory fills
7. **Latency degrades:** GC pauses cause observable latency spikes (P95/P99)
8. **Eventually OOM:** After 10-20 minutes, memory reaches 20Mi limit and process is killed
9. **Container restart:** Service restarts, pattern repeats if flag remains enabled

**Growth Pattern:**
- **0-5 minutes:** Memory climbs from 8Mi → 12Mi (60% utilization)
- **5-10 minutes:** Memory climbs from 12Mi → 16Mi (80% utilization), GC more frequent
- **10-15 minutes:** Memory climbs from 16Mi → 18Mi (90% utilization), noticeable latency impact
- **15-20 minutes:** Memory reaches 20Mi limit, OOM kill occurs

**Production Analog:** Simulates slow memory leaks from unclosed connections, growing caches, or gradual object accumulation that takes hours/days to manifest in production.

---

## Execution Steps

### Step 1: Check Current Checkout Service Status

```bash
# Check pod status
kubectl get pod -n otel-demo | grep checkout

# Check current memory usage
kubectl top pod -n otel-demo | grep checkout
```

### Step 2: Configure Feature Flag for Gradual Growth

1. **Access FlagD UI:**
   ```
   http://localhost:4000
   ```

2. **Edit kafkaQueueProblems flag:**
   - Find `kafkaQueueProblems` in the flag list
   - Click to edit
   - **Change the "on" variant value from 2000 to 300**
   - Or create a new variant:
     - Name: `gradual`
     - Value: `300`
   - **Set as default variant:** `gradual` or `on` (with value 300)
   - Save changes

**Critical:** The variant VALUE must be **300** (not 2000) for gradual growth.

### Step 3: Generate Moderate Load

1. **Access Locust Load Generator:**
   ```
   http://localhost:8089
   ```

2. **Configure load test:**
   - Click **"Edit"** button
   - **Number of users:** `25` (not 50!)
   - **Ramp up:** `3` (users per second)
   - **Runtime:** `30m` to `45m` (for gradual observation)
   - Click **"Start"**

**Why 25 users instead of 50:**
- Lower concurrency = slower checkout rate
- Gradual memory accumulation instead of spike
- More realistic production-like scenario

### Step 4: Monitor Memory Growth in Real-Time

**Watch memory usage (updates every 10s):**

```bash
# Memory usage for checkout pod
watch -n 10 "kubectl top pod -n otel-demo | grep checkout"
```

**Expected pattern with 300 flag value and 25 users:**
```
TIME    MEMORY
0m      8Mi    (baseline)
3m      10Mi   (gradual climb)
6m      12Mi   (steady growth)
9m      14Mi   (approaching 70%)
12m     16Mi   (80% utilization)
15m     18Mi   (90% - GC pressure)
18m     19Mi   (95% - critical)
20m     20Mi+  (OOM Kill → Restart → 8Mi)
```

**Check pod restarts:**
```bash
kubectl get pod -n otel-demo | grep checkout
```

Look for increasing `RESTARTS` count.

---

## Honeycomb Queries for Gradual Memory Leak

### Query 1: Memory Growth Trend (Primary Metric)

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(30s)
TIME RANGE: Last 1 hour
```

**What to look for:**
- Steady upward linear trend (not spiky)
- Grows from ~8Mi baseline
- Approaches 20Mi limit
- Drops to baseline after OOM kill/restart

### Query 2: Memory Utilization Percentage

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory_limit_utilization)
GROUP BY time(30s)
TIME RANGE: Last 1 hour
```

**Alert threshold:** > 0.85 (85% utilization)

**What to look for:**
- Starts at ~0.40 (40%)
- Climbs steadily to 0.85-0.95
- Drops to ~0.40 after restart

### Query 3: Go Runtime Heap Allocation

```
WHERE service.name = checkout
VISUALIZE MAX(process.runtime.go.mem.heap_alloc)
GROUP BY time(30s)
TIME RANGE: Last 1 hour
```

**Alternative if not available:**
```
WHERE service.name = checkout AND metric.name CONTAINS "heap"
VISUALIZE MAX(value)
GROUP BY time(30s)
```

### Query 4: Goroutine Count Growth

```
WHERE service.name = checkout AND metric.name = "process.runtime.go.goroutines"
VISUALIZE MAX(value)
GROUP BY time(30s)
TIME RANGE: Last 1 hour
```

**What to look for:** Increasing goroutine count correlates with memory growth.

### Query 5: Garbage Collection Frequency

```
WHERE service.name = checkout AND metric.name CONTAINS "gc"
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 1 hour
```

**What to look for:** Increasing GC frequency as memory pressure builds.

### Query 6: Checkout Request Rate

```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 1 hour
```

**Each checkout = N goroutines = memory growth**

### Query 7: Checkout Service Latency Degradation

```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
TIME RANGE: Last 1 hour
```

**What to look for:**
- Latency increases as memory fills up
- GC pauses cause latency spikes
- P99 grows significantly under memory pressure

### Query 8: Service Restart Detection

```
WHERE service.name = checkout
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 1 hour
```

**Pattern:** Gap in telemetry = service crashed and restarted

### Query 9: Memory Growth Rate (Derivative)

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE RATE_AVG(k8s.pod.memory.working_set)
GROUP BY time(1m)
TIME RANGE: Last 1 hour
```

**What to look for:** Positive rate = memory growing. Negative spike = restart.

### Query 10: Error Rate During Memory Pressure

```
WHERE service.name = checkout
VISUALIZE COUNT
GROUP BY otel.status_code
TIME RANGE: Last 1 hour
```

**What to look for:** Errors may increase as memory fills and GC pauses lengthen.

---

## Honeycomb Dashboard Configuration

Create a board named **"Checkout Service - Gradual Memory Leak Analysis"** with these panels:

### Panel 1: Memory Growth Trend
```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(30s)
```

### Panel 2: Memory Utilization %
```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory_limit_utilization)
GROUP BY time(30s)
```

### Panel 3: Checkout Request Rate
```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY time(1m)
```

### Panel 4: Checkout Latency
```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

### Panel 5: Goroutine Count
```
WHERE service.name = checkout AND metric.name = "process.runtime.go.goroutines"
VISUALIZE MAX(value)
GROUP BY time(30s)
```

### Panel 6: GC Frequency
```
WHERE service.name = checkout AND metric.name CONTAINS "gc"
VISUALIZE COUNT
GROUP BY time(1m)
```

### Panel 7: Service Availability
```
WHERE service.name = checkout
VISUALIZE COUNT
GROUP BY time(1m)
```

### Panel 8: Memory Growth Rate
```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE RATE_AVG(k8s.pod.memory.working_set)
GROUP BY time(1m)
```

---

## Expected Timeline

### With Flag Value 300 and 25 Users

| Time | Memory | Utilization | Goroutines | Status | Observable |
|------|--------|-------------|------------|--------|-----------|
| 0m | 8Mi | 40% | ~50 | Baseline | Normal operation |
| 3m | 10Mi | 50% | ~200 | Growing | Slight increase |
| 6m | 12Mi | 60% | ~400 | Steady climb | P95 latency up 10% |
| 9m | 14Mi | 70% | ~600 | Pressure building | GC more frequent |
| 12m | 16Mi | 80% | ~800 | High pressure | P99 latency up 30% |
| 15m | 18Mi | 90% | ~1000 | Critical | GC pauses noticeable |
| 18m | 19Mi | 95% | ~1200 | Pre-OOM | Latency spikes |
| 20m | 20Mi+ | 100%+ | N/A | **OOM Kill** | **Service crashes** |
| 20m+30s | 8Mi | 40% | ~50 | Restarted | Back to baseline |

### Comparing Flag Values (25 users)

| Flag | Time to 50% | Time to 80% | Time to OOM | Pattern |
|------|-------------|-------------|-------------|---------|
| 100 | 8m | 20m | 30-40m | Very gradual |
| 200 | 4m | 10m | 15-20m | Gradual |
| 300 | 3m | 7m | 10-15m | Moderate |
| 500 | 2m | 4m | 5-7m | Fast |
| 2000 | 30s | 60s | 90s | Spike (not leak) |

---

## Alert Configuration

### Alert 1: Memory Growth Trend

```
TRIGGER: MAX(k8s.pod.memory_limit_utilization) > 0.70
WHERE: k8s.pod.name STARTS_WITH checkout
FREQUENCY: Every 1 minute
ACTION: Warning - memory leak detected
```

### Alert 2: Critical Memory Threshold

```
TRIGGER: MAX(k8s.pod.memory_limit_utilization) > 0.85
WHERE: k8s.pod.name STARTS_WITH checkout
FREQUENCY: Every 30 seconds
ACTION: Critical - imminent OOM
```

### Alert 3: Memory Growth Rate Alert

```
TRIGGER: RATE_AVG(k8s.pod.memory.working_set) > 500000
WHERE: k8s.pod.name STARTS_WITH checkout
FREQUENCY: Every 1 minute
ACTION: Memory growing too fast
```

### Alert 4: Service Degradation

```
TRIGGER: P95(duration_ms) > 500
WHERE: service.name = checkout AND name = PlaceOrder
FREQUENCY: Every 1 minute
ACTION: Performance degradation
```

### Alert 5: Service Restart Detection

```
TRIGGER: COUNT < 5
WHERE: service.name = checkout
FREQUENCY: Every 1 minute
ACTION: Service may have restarted
```

---

## Trace and Log Correlation

### Finding Impacted Traces

1. **Identify slow checkouts during memory pressure:**
   ```
   WHERE service.name = checkout AND name = PlaceOrder AND duration_ms > 1000
   VISUALIZE HEATMAP(duration_ms)
   GROUP BY time(1m)
   ```

2. **Click on a slow trace** to see:
   - Full trace showing entire checkout flow
   - Spans showing where time was spent
   - GC pauses may appear as slow spans

3. **Correlate with memory metrics:**
   - Note the timestamp of slow trace
   - Check memory utilization at that time
   - Correlation: High memory = slow checkouts

### Example Correlation Flow

1. User initiates checkout at `10:15:23`
2. Checkout service is at 85% memory (17Mi / 20Mi)
3. Checkout spawns 300 goroutines
4. GC triggers due to memory pressure
5. GC pause: 500ms
6. Checkout completes in 2500ms (normally 200ms)
7. User sees slow checkout experience

**Honeycomb Trace Query:**
```
WHERE service.name = checkout AND name = PlaceOrder AND duration_ms > 2000
VISUALIZE TRACES
```

Click a trace → See slow spans → Correlate with memory metric at that timestamp.

---

## Cleanup

### Stop Load Test
1. Go to Locust UI: http://localhost:8089
2. Click **"Stop"** button

### Disable or Reduce Feature Flag
1. Go to FlagD UI: http://localhost:4000
2. Set `kafkaQueueProblems` variant "on" back to **`0`** or **`off`**
3. Or change default variant to **`off`**

### Restart Checkout Service (to clear memory)
```bash
kubectl rollout restart deployment checkout -n otel-demo
```

---

## Comparison: Gradual Leak vs Sudden Spike (Same Flag!)

| Aspect | Gradual Leak | Sudden Spike |
|--------|--------------|--------------|
| **Flag Value** | 200-500 | 2000+ |
| **Load** | 25 users | 50 users |
| **Pattern** | Linear, steady growth | Exponential, rapid spike |
| **Time to OOM** | 10-30 minutes | 60-90 seconds |
| **Predictability** | Very predictable | Less predictable |
| **GC Behavior** | Increasing GC frequency | GC can't keep up |
| **Latency Impact** | Gradual degradation | Sudden failure |
| **Monitoring** | Trends, thresholds | Spike detection |
| **Real-world** | Memory leaks in production | Memory bombs, goroutine leaks |
| **Alerting** | Trend-based alerts work well | Must catch spike quickly |

**Key Insight:** Same feature flag, different configuration = different failure modes!

---

## Troubleshooting

### Memory Not Growing Gradually

**Check flag value:**
- Go to FlagD UI: http://localhost:4000
- Verify `kafkaQueueProblems` "on" variant = **300** (not 2000)
- Verify default variant is set to "on"

**Check load:**
- Are you running 25 users (not 50)?
- Higher load = faster growth (less gradual)

**Check if checkouts are happening:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=50 | grep "order placed"
```

### Memory Growing Too Fast

**Reduce flag value:**
- Change from 300 to 200 or 100 in FlagD UI

**Reduce load:**
- Lower Locust users from 25 to 20 or 15

### Memory Not Reaching OOM

**Memory limit might be too high:**
```bash
kubectl get deployment checkout -n otel-demo -o yaml | grep -A 3 "limits:"
```

Should show 20Mi.

**Increase flag value:**
- Change from 200 to 300 or 400

**Increase load:**
- Raise Locust users from 25 to 30

### Comparing Against Spike Scenario

Run both scenarios side-by-side in Honeycomb:

**Gradual (300 flag, 25 users):**
```
WHERE k8s.pod.name = checkout-gradual
VISUALIZE MAX(k8s.pod.memory.working_set)
```

**Spike (2000 flag, 50 users):**
```
WHERE k8s.pod.name = checkout-spike
VISUALIZE MAX(k8s.pod.memory.working_set)
```

Compare the growth curves.

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **Gradual memory leak pattern** (linear growth over time)
2. ✅ **Goroutine accumulation** as root cause
3. ✅ **GC frequency increasing** under memory pressure
4. ✅ **Service latency degradation** correlated with memory usage
5. ✅ **Predictable time-to-failure** with trend analysis
6. ✅ **Trace correlation** showing impacted user requests
7. ✅ **Alert threshold tuning** for gradual vs sudden failures
8. ✅ **Same flag, different behavior** based on configuration
9. ✅ **Real-world memory leak** simulation

---

## Key Takeaways

### For Observability:

- **Trend analysis** is critical for detecting gradual leaks
- **Rate of change** matters more than absolute values
- **Multi-metric correlation** (memory + goroutines + latency + GC) provides full picture
- **Baseline comparison** helps identify abnormal growth

### For Alerting:

- Use **rate-of-change alerts** not just static thresholds
- **Tiered alerts**: Warning at 70%, Critical at 85%
- **Predictive alerts**: "At this rate, OOM in 10 minutes"
- **Combine metrics**: Memory + latency + error rate

### For Production:

- Gradual leaks are **harder to detect** than sudden spikes
- May go unnoticed for hours/days in production
- **Heap dumps** and profiling needed for root cause
- **Regular restarts** may mask the problem (but don't fix it)
- **Monitoring trends** catches leaks before they cause outages

---

## Next Steps

### Extend the Use Case

1. **Compare with sudden spike:**
   - Run gradual (300) and spike (2000) back-to-back
   - Compare Honeycomb dashboards
   - Different monitoring strategies needed

2. **Test different flag values:**
   - Try 100, 200, 300, 500
   - Observe different growth rates
   - Tune alerting thresholds

3. **Implement circuit breaker:**
   - Add logic to disable flag when memory > 80%
   - Prevent OOM with proactive flag disable

4. **Test with different loads:**
   - 15 users (very gradual)
   - 25 users (moderate)
   - 35 users (faster)

---

## Summary

This use case demonstrates **gradual memory leak with heap pressure** using:
- ✅ Feature flag for dynamic control (`kafkaQueueProblems`)
- ✅ **Lower flag values (200-500)** for gradual growth
- ✅ **Moderate load (25 users)** for realistic scenario
- ✅ Predictable, linear growth pattern
- ✅ Observable in Honeycomb with trend analysis
- ✅ ZERO code changes required
- ✅ Realistic production memory leak scenario
- ✅ Trace and log correlation showing user impact
- ✅ Dashboard with upward trends and GC pressure
- ✅ Alert configuration for threshold and rate-of-change

**Key difference from spike:** This is a **slow, gradual leak** that mimics real-world production memory issues - harder to detect but easier to predict once identified.

**Same flag, different scenario:** By adjusting the flag VALUE and LOAD, you can demonstrate both gradual leak (this guide) and sudden spike (memory-tracking-spike-crash.md).
