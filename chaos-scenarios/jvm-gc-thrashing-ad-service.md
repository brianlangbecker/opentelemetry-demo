# JVM Garbage Collection Thrashing - Ad Service

## Overview

This guide demonstrates how to observe **JVM garbage collection thrashing and stop-the-world pauses** using the OpenTelemetry Demo's ad service (Java), with telemetry sent to Honeycomb for analysis.

### Use Case Summary

- **Target Service:** `ad` (Java microservice)
- **Memory Limit:** 300Mi
- **Trigger Mechanism:** Feature flag (`adManualGc`) + Load generator
- **Observable Outcome:** Repeated GC cycles → Heap pressure → Latency spikes → Performance degradation
- **Pattern:** Cyclical GC storms without crash (zombie service pattern)
- **Monitoring:** Honeycomb UI for latency spikes, heap oscillation, and GC correlation

---

## Related Scenarios

| Scenario | Language | Pattern | Observable Outcome |
|----------|----------|---------|-------------------|
| **[Memory Spike](memory-tracking-spike-crash.md)** | Go | Linear growth | OOM crash in 60-90s |
| **[Gradual Memory Leak](memory-leak-gradual-checkout.md)** | Go | Gradual climb | OOM in 10-20m |
| **[JVM GC Thrashing](jvm-gc-thrashing-ad-service.md)** | Java | Cyclical GC | Latency spikes without crash (this guide) |

**Key Difference:** This demonstrates a **zombie service** - stays alive but becomes periodically unresponsive due to GC pressure. Common JVM production issue that's harder to detect than outright crashes.

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- Kubernetes cluster with kubectl access
- Access to Honeycomb UI
- FlagD UI accessible

---

## How It Works

When `adManualGc` flag is enabled, each ad request triggers aggressive garbage collection:

1. Heap is filled to 90% capacity with objects
2. Creates 500,000 objects with expensive finalizers
3. Triggers 10 consecutive full GC cycles
4. Each GC cycle causes "stop-the-world" pauses
5. Process repeats every 10 seconds
6. Results in dramatic latency spikes and degraded performance

**This simulates:** Production JVM services under memory pressure with frequent GC pauses.

---

## Execution Steps

### Step 1: Check Current Ad Service Status

```bash
# Check pod status
kubectl get pod -n otel-demo | grep ad

# Check current memory and CPU usage
kubectl top pod -n otel-demo | grep ad
```

**Baseline:** Ad service should be using ~50-100Mi memory normally.

### Step 2: Enable GC Thrashing Feature Flag

1. **Access FlagD UI:**

   ```
   http://localhost:4000
   ```

2. **Enable the flag:**
   - Find `adManualGc` in the flag list
   - Click to expand/edit it
   - Set the default variant to **`on`**
   - Save changes

**What this does:** Every ad request will trigger aggressive GC cycles that fill the heap and run 10 full garbage collections.

### Step 3: Generate Load

Ads are requested on every page view, so we need sustained browsing traffic.

1. **Access Locust Load Generator:**

   ```
   http://localhost:8089
   ```

2. **Configure load test:**
   - Click **"Edit"** button
   - **Number of users:** `50` (sustained load)
   - **Ramp up:** `5` (users per second)
   - **Runtime:** `30m` (to observe pattern over time)
   - Click **"Start"**

**Why this works:** The browse task (weight=10) generates lots of page views, and each page view requests ads from the ad service.

### Step 3.5: (Optional) Lower Memory Limit for Faster OOM

**For a more dramatic demo with faster death spiral:**

```bash
# Lower memory limit from 300Mi to 200Mi
kubectl set resources deployment ad -n otel-demo --limits=memory=200Mi

# Wait for pod to restart with new limit
kubectl rollout status deployment ad -n otel-demo
```

**This makes the demo more effective by:**
- Causing OOM in 2-5 minutes instead of 10-20 minutes
- Creating visible restart cycles in Honeycomb
- Showing clear "death → rebirth → death" pattern

**Skip this step if you want:**
- Longer-running demo (stays in zombie mode)
- No configuration changes
- Just GC thrashing without OOM crashes

### Step 4: Monitor GC Impact in Real-Time

**Watch memory usage (updates every 10s):**

```bash
watch -n 10 "kubectl top pod -n otel-demo | grep ad"
```

**Expected pattern:**

```
TIME    MEMORY   CPU
0m      80Mi     5%     (baseline)
1m      250Mi    60%    (heap filling)
1m 10s  270Mi    95%    (GC thrashing)
1m 15s  100Mi    70%    (post-GC)
1m 30s  250Mi    60%    (heap filling again)
1m 40s  270Mi    95%    (GC thrashing again)
...repeating pattern...
```

**Check logs for GC events:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=ad --tail=50 | grep -i "garbage collection"
```

Expected log output:

```
Triggering a manual garbage collection, next one in 10 seconds.
The artificially triggered GCs took: 2547 ms
```

---

## Honeycomb Queries for GC Thrashing

### Key Metrics Summary

**Top 3 Metrics to Show Death Spiral:**

| Priority | Metric | Pattern | What It Shows |
|----------|--------|---------|---------------|
| **#1** | `jvm.gc.duration` | **Continuously rising** | GC taking longer each time (1.5s → 8s) |
| **#2** | `jvm.memory.used` | **Staircase climbing** | Memory not being freed (100Mi → 250Mi) |
| **#3** | Latency (P99) | **Progressive degradation** | User impact (2s → 10s) |

**Supporting Metrics:**
- `jvm.memory.committed` - JVM requesting more OS memory
- `jvm.thread.count` - Thread activity during GC
- CPU utilization - Spikes during GC cycles

**Standard OpenTelemetry Java Metrics (Usually Available):**
- ✅ `jvm.gc.duration` - GC pause time
- ✅ `jvm.memory.used` - Heap memory in use
- ✅ `jvm.memory.committed` - Memory allocated from OS
- ✅ `jvm.memory.limit` - Max heap size
- ✅ `jvm.thread.count` - Number of threads
- ✅ `jvm.class.loaded` - Loaded classes
- ✅ `jvm.class.unloaded` - Unloaded classes

**Extended Metrics (May Not Be Available):**
- ⚠️ `jvm.memory.objects_pending_finalization` - Objects awaiting finalization
- ⚠️ `jvm.gc.overhead` - Percentage of time in GC
- ⚠️ `jvm.cpu.time` - CPU time by state

**Note:** Check what's available in your Honeycomb dataset by exploring the `service.name = ad` data.

---

### Quick Reference: Visualizations and Aggregations

| Metric | Aggregation | Why | What It Shows |
|--------|-------------|-----|---------------|
| `jvm.gc.duration` | **AVG(LAST())** or **MAX()** | GC duration per event | Continuously rising (death spiral) |
| `jvm.memory.used` | **MAX()** or **SUM()** | Peak usage in window | Staircase pattern climbing |
| `jvm.memory.committed` | **MAX()** or **SUM()** | Total committed | JVM allocating more OS memory |
| `jvm.memory.limit` | **MAX()** | Max heap size (constant) | Shows ceiling before OOM |
| `jvm.thread.count` | **MAX()** or **AVG()** | Peak/avg threads | Thread activity (usually stable) |
| `k8s.pod.cpu_utilization` | **MAX()** or **AVG()** | Peak/avg CPU | Spikes during GC cycles |
| `k8s.pod.memory.working_set` | **MAX()** | Peak memory usage | Pod memory staircase |
| Latency (duration_ms) | **P99()** or **P95()** | Worst-case latency | User impact degradation |

**Aggregation Guidelines:**

- **`AVG(LAST())`** - For cumulative counters like `jvm.gc.duration` (gets latest value per time bucket, then averages)
- **`MAX()`** - For gauges showing current state (memory, threads, CPU) - shows peak in time window
- **`SUM()`** - When combining multiple pools/sources (e.g., all heap pools combined)
- **`P99()` / `P95()`** - For latency to show user-facing impact (worst-case experience)

**Examples:**

```
# GC Duration (growing death spiral)
WHERE service.name = ad
VISUALIZE AVG(LAST(jvm.gc.duration))
GROUP BY time(30s)

# Memory Used (staircase pattern) - Single pool
WHERE service.name = ad
VISUALIZE MAX(jvm.memory.used)
GROUP BY time(30s), pool

# Memory Used (staircase pattern) - All pools combined
WHERE service.name = ad
VISUALIZE SUM(jvm.memory.used)
GROUP BY time(30s)

# CPU (spikes during GC)
WHERE k8s.pod.name STARTS_WITH ad
VISUALIZE MAX(k8s.pod.cpu_utilization)
GROUP BY time(10s)

# Latency (user impact)
WHERE service.name = ad
VISUALIZE P99(duration_ms), P95(duration_ms)
GROUP BY time(30s)
```

**Key Visualization Patterns:**
- 📈 **Rising line** = Death spiral (GC duration, memory baseline)
- 🪜 **Staircase** = Memory leak (memory used/committed)
- 📊 **Spikes** = GC events (CPU, latency)
- 🎨 **Heatmap bands** = Periodic GC pauses (latency)

---

### Query 1: Ad Service Latency Spikes (Primary Indicator)

```
WHERE service.name = ad
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**Alternative (if you want to filter to specific RPC):**

```
WHERE service.name = ad AND (name = "oteldemo.AdService/GetAds" OR name = "GetAds" OR name CONTAINS "GetAds")
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**What to look for:**

- P50 baseline: ~low ms
- During GC: P95 jumps to 10 to 20x from p50
- Cyclical pattern repeating every 10 seconds

### Query 2: Ad Service Latency Heatmap

```
WHERE service.name = ad
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**

- Vertical bands of slow requests (stop-the-world GC)
- Repeating pattern every 10 seconds
- Most requests are fast, but periodic clusters are very slow

### Query 3: Ad Service Request Rate

```
WHERE service.name = ad
VISUALIZE COUNT
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**What to look for:**

- Throughput drops during GC cycles
- Request rate oscillates as GC blocks processing

### Query 4: JVM Heap Usage (if available)

```
WHERE service.name = ad AND metric.name = "process.runtime.jvm.memory.usage"
VISUALIZE MAX(value)
GROUP BY time(10s), pool
TIME RANGE: Last 30 minutes
```

**Alternative query:**

```
WHERE k8s.pod.name STARTS_WITH ad
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**What to look for:**

**Pattern A - Sawtooth (if memory is being reclaimed):**
- Gradual climb → sharp drop (GC) → climb again
- Heap fills to ~270Mi → GC → drops to ~100Mi
- Pattern repeats continuously

**Pattern B - Growing baseline (memory leak - more common):**
- Memory climbs after each GC, but doesn't drop as much
- Baseline keeps rising: 100Mi → 120Mi → 150Mi → 180Mi
- Eventually approaches limit and OOM
- **This indicates objects aren't being garbage collected properly**

### Query 5: GC Duration Growth (PRIMARY INDICATOR - Use This!)

**This is the KEY metric showing the death spiral you're observing.**

```
WHERE service.name = ad
VISUALIZE AVG(LAST(jvm.gc.duration))
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**Alternative aggregations:**
```
WHERE service.name = ad
VISUALIZE MAX(jvm.gc.duration), AVG(jvm.gc.duration), P95(jvm.gc.duration)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- **Continuously rising line** (not cyclical!)
- Starts at ~1500ms, grows to 2000ms → 3000ms → 5000ms → 8000ms+
- **This is the death spiral** - each GC takes longer because there's more un-collectable garbage
- Eventually flatlines at OOM crash

**Also check logs for correlation:**

```bash
# Kubernetes
kubectl logs -n otel-demo -l app.kubernetes.io/name=ad | grep "artificially triggered GCs took"

# Docker Compose
docker logs ad | grep "artificially triggered GCs took"
```

**Pattern:** If GC time keeps growing, it means:
- Heap is filling with un-collectable objects (memory leak)
- Each GC has more work to do but can't free memory
- Service heading toward **GC death spiral** → OOM

### Query 6: JVM Heap Memory Used (Shows Leak)

**This should show memory NOT being released after GC.**

```
WHERE service.name = ad
VISUALIZE MAX(jvm.memory.used)
GROUP BY time(30s), pool
TIME RANGE: Last 30 minutes
```

**Alternative (combined pools):**
```
WHERE service.name = ad
VISUALIZE SUM(jvm.memory.used)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- **Staircase pattern** (not sawtooth!)
- Memory goes up, GC happens, but doesn't drop all the way down
- Baseline keeps climbing: 100Mi → 150Mi → 200Mi → 250Mi
- Eventually approaches `jvm.memory.limit` before OOM

### Query 7: JVM Heap Utilization Ratio

**Shows how close to OOM you're getting.**

```
WHERE service.name = ad
VISUALIZE AVG(jvm.memory.used / jvm.memory.limit)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**Alternative (if division doesn't work):**
```
WHERE service.name = ad
VISUALIZE MAX(jvm.memory.used), MAX(jvm.memory.limit)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Ratio climbing: 0.3 → 0.5 → 0.7 → 0.9 → 1.0 (OOM)
- When it hits 0.95+ consistently, OOM is imminent

### Query 8: JVM Memory Committed (Alternative Growth Indicator)

**Shows how much memory the JVM has allocated from the OS.**

```
WHERE service.name = ad
VISUALIZE MAX(jvm.memory.committed)
GROUP BY time(30s), pool
TIME RANGE: Last 30 minutes
```

**Alternative (combined):**
```
WHERE service.name = ad
VISUALIZE SUM(jvm.memory.committed)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Committed memory growing as JVM tries to allocate more heap
- Shows JVM requesting more OS memory to handle the leak
- May plateau at the limit before OOM

**Note:** If `jvm.memory.objects_pending_finalization` metric is available in your setup, use this query instead:
```
WHERE service.name = ad
VISUALIZE MAX(jvm.memory.objects_pending_finalization)
GROUP BY time(30s)
```
This would show objects waiting to be finalized (root cause of the leak).

### Query 9: JVM Thread Count (Secondary Indicator)

**High thread count can contribute to GC pressure.**

```
WHERE service.name = ad
VISUALIZE MAX(jvm.thread.count)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- May increase slightly under load
- Dramatic increase indicates thread leak (different issue)

### Query 10: JVM GC Overhead Ratio

**Shows what % of time is spent in GC vs doing work.**

```
WHERE service.name = ad
VISUALIZE AVG(jvm.gc.overhead)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**Alternative (calculate manually):**
```
WHERE service.name = ad
VISUALIZE COUNT_DISTINCT(jvm.gc.duration > 0)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Should be < 10% normally
- Death spiral: climbs to 30% → 50% → 80%+
- When spending most time in GC, service is effectively dead

### Query 11: CPU Utilization During GC

**Shows CPU being consumed during garbage collection.**

```
WHERE k8s.pod.name STARTS_WITH ad
VISUALIZE AVG(k8s.pod.cpu_utilization)
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- CPU spikes correlate with GC cycles
- As GC takes longer, CPU stays elevated
- Combined with high latency = GC thrashing

### Query 12: Error Rate During GC

```
WHERE service.name = ad
VISUALIZE COUNT
GROUP BY otel.status_code
TIME RANGE: Last 30 minutes
```

**What to look for:**

- Some requests may timeout during long GC pauses
- Error rate may increase during GC storms

### Query 13: Upstream Impact (Frontend Latency)

```
WHERE service.name = frontend AND name CONTAINS "ad"
VISUALIZE P95(duration_ms), P99(duration_ms)
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**What to look for:**

- Frontend sees increased latency when calling ad service
- User-facing impact of backend GC issues

### Query 14: Ad Request Type Breakdown

```
WHERE service.name = ad
VISUALIZE COUNT, AVG(duration_ms)
GROUP BY app.ads.ad_request_type
TIME RANGE: Last 30 minutes
```

**What to look for:**

- Both targeted and random ad requests affected equally
- GC impacts all request types

### Query 15: Concurrent Request Impact

```
WHERE service.name = ad
VISUALIZE MAX(duration_ms)
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**What to look for:**

- Max latency shows worst-case user experience
- Some users hit peak GC pause times

### Query 16: CPU Utilization During GC

```
WHERE k8s.pod.name STARTS_WITH ad
VISUALIZE MAX(k8s.pod.cpu_utilization)
GROUP BY time(10s)
TIME RANGE: Last 30 minutes
```

**What to look for:**

- CPU spikes during GC cycles
- GC is CPU-intensive work
- CPU drops after GC completes

---

## Honeycomb Dashboard Configuration

Create a board named **"Ad Service - JVM GC Death Spiral"** with these panels:

### Panel 1: 🔴 GC Duration Growth (CRITICAL - Death Spiral Indicator)

```
WHERE service.name = ad
VISUALIZE AVG(LAST(jvm.gc.duration))
GROUP BY time(30s)
```

**Expected:** Continuously rising line (1.5s → 2s → 3s → 5s → 8s)

### Panel 2: 🟠 Heap Memory Used (Memory Leak Pattern)

```
WHERE service.name = ad
VISUALIZE SUM(jvm.memory.used)
GROUP BY time(30s)
```

**Expected:** Staircase climbing (100Mi → 150Mi → 200Mi → 250Mi)

### Panel 3: 🟡 Latency P99 (User Impact)

```
WHERE service.name = ad
VISUALIZE P99(duration_ms)
GROUP BY time(30s)
```

**Expected:** Progressive degradation (2s → 5s → 10s)

### Panel 4: Memory Committed (JVM Growth)

```
WHERE service.name = ad
VISUALIZE SUM(jvm.memory.committed)
GROUP BY time(30s)
```

**Expected:** Growing as JVM allocates more heap from OS

### Panel 5: Latency Heatmap (Visual Impact)

```
WHERE service.name = ad
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
```

**Expected:** Vertical bands getting darker over time

### Panel 6: Heap Utilization Ratio

```
WHERE service.name = ad
VISUALIZE MAX(jvm.memory.used), MAX(jvm.memory.limit)
GROUP BY time(30s)
```

**Expected:** Gap narrowing as approaching OOM

### Panel 7: Request Throughput

```
WHERE service.name = ad
VISUALIZE COUNT
GROUP BY time(10s)
```

**Expected:** Throughput drops as GC dominates

### Panel 8: CPU Utilization

```
WHERE k8s.pod.name STARTS_WITH ad
VISUALIZE MAX(k8s.pod.cpu_utilization)
GROUP BY time(10s)
```

**Expected:** High and sustained during GC cycles

### Panel 9: Error Rate

```
WHERE service.name = ad
VISUALIZE COUNT
GROUP BY otel.status_code
```

**Expected:** Errors increase as latency exceeds timeouts

---

## Expected Timeline

### Pattern A: Clean GC Cycles (Ideal - Rarely Seen)

| Time | Heap  | CPU | GC Duration | Latency     | Status       |
| ---- | ----- | --- | ----------- | ----------- | ------------ |
| 0s   | 80Mi  | 5%  | N/A         | P99: 50ms   | Baseline     |
| 20s  | 270Mi | 95% | 1500ms      | P99: 2000ms | **GC Storm** |
| 25s  | 100Mi | 70% | N/A         | P99: 50ms   | Post-GC      |
| 45s  | 270Mi | 95% | 1500ms      | P99: 2000ms | **GC Storm** |
| 50s  | 100Mi | 70% | N/A         | P99: 50ms   | Post-GC      |
| ...  | ...   | ... | **~1500ms** | ...         | **Stable**   |

### Pattern B: Growing GC Time (Most Common - Memory Leak)

| Time  | Heap  | CPU | GC Duration  | Latency      | Status              |
| ----- | ----- | --- | ------------ | ------------ | ------------------- |
| 0s    | 80Mi  | 5%  | N/A          | P99: 50ms    | Baseline            |
| 20s   | 270Mi | 95% | **1547ms**   | P99: 2000ms  | **GC Storm**        |
| 25s   | 120Mi | 70% | N/A          | P99: 100ms   | Post-GC (leak)      |
| 45s   | 280Mi | 95% | **2234ms**   | P99: 3000ms  | **GC Storm**        |
| 50s   | 150Mi | 75% | N/A          | P99: 150ms   | Post-GC (worse)     |
| 70s   | 285Mi | 95% | **3891ms**   | P99: 5000ms  | **GC Storm**        |
| 75s   | 180Mi | 80% | N/A          | P99: 200ms   | Post-GC (critical)  |
| 95s   | 290Mi | 98% | **5672ms**   | P99: 7000ms  | **Death Spiral**    |
| 100s  | 210Mi | 85% | N/A          | P99: 300ms   | Pre-OOM             |
| 120s  | 295Mi | 99% | **8234ms**   | P99: 10000ms | **Critical**        |
| 125s+ | OOM   | -   | -            | -            | **Service Crashes** |

**Key Patterns:**

**Pattern A (Sawtooth):** Service stays degraded but stable
- GC duration stays constant (~1500ms)
- Memory drops back to baseline after GC
- Service survives indefinitely (zombie mode)

**Pattern B (Growing GC - What you're seeing):** Service heading toward death
- **GC duration grows:** 1547ms → 2234ms → 3891ms → 5672ms → 8234ms
- **Memory baseline rises:** 100Mi → 120Mi → 150Mi → 180Mi → 210Mi
- **Latency worsens:** P99 climbs from 2s → 10s
- **Eventually OOMs** after 2-5 minutes

---

## Trace and Log Correlation

### Finding GC-Impacted Traces

1. **Identify slow ad requests during GC:**

   ```
   WHERE service.name = ad AND duration_ms > 1000
   VISUALIZE TRACES
   ORDER BY duration_ms DESC
   LIMIT 20
   ```

2. **Click on a slow trace** to see:

   - Full trace from frontend → ad service
   - Long span duration for `GetAds` operation
   - No child spans (time spent in GC, not business logic)
   - Timestamp correlates with GC cycle

3. **Correlate with logs:**

   ```bash
   kubectl logs -n otel-demo -l app.kubernetes.io/name=ad | grep "artificially triggered GCs"
   ```

   Match the log timestamp with the slow trace timestamp.

### Example Correlation Flow

1. User browses product page at `10:15:20`
2. Frontend requests ads from ad service
3. Ad service receives request at `10:15:20.100`
4. `adManualGc` flag is enabled
5. Ad service fills heap to 90% and triggers 10 GC cycles
6. GC takes 2500ms (logged: "The artificially triggered GCs took: 2547 ms")
7. Ad service responds at `10:15:22.647` (2.5 seconds later!)
8. User sees slow page load

**Honeycomb Trace Query:**

```
WHERE service.name = ad AND duration_ms > 2000
VISUALIZE TRACES
```

Click a trace → See the entire 2.5 second span → Correlate with GC log timestamp.

---

## Alert Configuration

### Alert 1: High Latency (GC Indicator)

```
TRIGGER: P95(duration_ms) > 500
WHERE: service.name = ad
FREQUENCY: Every 1 minute
ACTION: Warning - Ad service experiencing high latency (possible GC pressure)
```

### Alert 2: Extreme Latency

```
TRIGGER: P99(duration_ms) > 2000
WHERE: service.name = ad
FREQUENCY: Every 30 seconds
ACTION: Critical - Ad service severely degraded (likely GC thrashing)
```

### Alert 3: Throughput Drop

```
TRIGGER: COUNT < 50
WHERE: service.name = ad
FREQUENCY: Every 1 minute
ACTION: Ad service throughput dropped (possible GC blocking)
```

### Alert 4: Memory Pressure

```
TRIGGER: MAX(k8s.pod.memory.working_set) > 250000000
WHERE: k8s.pod.name STARTS_WITH ad
FREQUENCY: Every 30 seconds
ACTION: Ad service memory pressure (heap filling)
```

---

## Cleanup

### Stop Load Test

1. Go to Locust UI: http://localhost:8089
2. Click **"Stop"** button

### Disable Feature Flag

1. Go to FlagD UI: http://localhost:4000
2. Set `adManualGc` back to **`off`**

### Restart Ad Service (to clear state)

```bash
kubectl rollout restart deployment ad -n otel-demo
```

---

## Troubleshooting

### Not Seeing Latency Spikes

**Verify flag is enabled:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=ad | grep "adManualGc"
```

Should see: `"Feature Flag adManualGc enabled, performing a manual gc now"`

**Check if ads are being requested:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=ad | grep "ad request received"
```

Should see frequent ad requests.

**Increase load:**

- Raise Locust users from 50 to 75 or 100
- More users = more ad requests = more GC cycles

### GC Happening But Latency Not Visible in Honeycomb

**Check query time range:**

- Ensure you're looking at recent data (Last 30 minutes)
- GC cycles happen every 10 seconds, so should be visible

**Check if metrics are flowing:**

```
WHERE service.name = ad
VISUALIZE COUNT
TIME RANGE: Last 5 minutes
```

If no data, check Honeycomb export configuration.

### GC Duration Plateauing (Not Growing to OOM)

**If GC time stabilizes instead of continuously growing:**

This means GC is barely keeping up - the service is in "zombie mode" but not dying. To push it further:

**Option 1: Increase Load**
- Raise Locust users from 50 to **75 or 100**
- More ad requests = more GC triggers = faster memory accumulation
- Should push past the plateau to OOM

**Option 2: Lower Memory Limit (Kubernetes only) - RECOMMENDED FOR DRAMATIC DEMO**

```bash
# Reduce memory limit to push service to OOM faster
kubectl set resources deployment ad -n otel-demo --limits=memory=200Mi
```

**What this does:**
- Reduces limit from 300Mi → 200Mi
- Triggers rolling restart with new limit
- Makes OOM much more likely (currently running at ~293Mi)
- Creates faster, more dramatic death spiral

**Verify the change:**
```bash
kubectl get deployment ad -n otel-demo -o yaml | grep -A 2 "limits:"
```

**Watch it in real-time:**
```bash
watch -n 5 "kubectl top pod -n otel-demo | grep ad"
```

**Expected behavior with 200Mi limit:**
- Service starts at ~80Mi baseline
- Climbs to ~150Mi in 1-2 minutes
- Hits 200Mi limit in 2-5 minutes
- **OOM kill** → Restart → Cycle repeats
- **Much more dramatic oscillation** in Honeycomb

**To revert back to 300Mi later:**
```bash
kubectl set resources deployment ad -n otel-demo --limits=memory=300Mi
```

**Note:** This modifies the deployment (against "no config changes" rule, but makes demo more effective)

**Option 3: Run Longer**
- Current plateau may be temporary
- Let it run for 10-15 minutes
- Memory leak may still be accumulating slowly
- Eventually will tip over to OOM

**Option 4: Combine with CPU Load**
- Enable **both** `adManualGc: on` AND `adHighCpu: on`
- Combined stress pushes system harder
- More likely to exceed limits

### Service Crashing Instead of GC Thrashing

**Memory limit might be too low:**

- Ad service needs 300Mi to survive GC cycles (for thrashing demo)
- For OOM demo, 200Mi works better
- Check with: `kubectl get deployment ad -n otel-demo -o yaml | grep memory`

**If crashing too fast, disable flag immediately:**

```
# Go to FlagD UI and turn off adManualGc
```

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **JVM garbage collection patterns** in production-like scenarios
2. ✅ **Stop-the-world GC pauses** causing latency spikes
3. ✅ **Sawtooth memory patterns** (heap fill → GC → repeat)
4. ✅ **Cyclical performance degradation** (not a crash, but periodic slowness)
5. ✅ **CPU spikes during GC** activity
6. ✅ **User-facing impact** of backend GC issues
7. ✅ **Trace correlation** showing which requests hit GC pauses
8. ✅ **Difference between OOM crash vs GC thrashing**
9. ✅ **JVM-specific observability** patterns

---

## Comparison: JVM GC Thrashing vs Go Memory Spike

| Aspect         | JVM GC Thrashing (Ad)         | Go Memory Spike (Checkout)        |
| -------------- | ----------------------------- | --------------------------------- |
| **Language**   | Java                          | Go                                |
| **Pattern**    | Cyclical (repeating)          | Linear (continuous growth)        |
| **Outcome**    | Performance degradation       | OOM crash                         |
| **Memory**     | Oscillates (sawtooth)         | Grows until limit                 |
| **Latency**    | Periodic spikes               | Gradual increase then crash       |
| **Recovery**   | Automatic (GC clears)         | Restart required                  |
| **CPU**        | High during GC                | Moderate                          |
| **Real-world** | Undersized heap, memory leaks | Goroutine leaks, unbounded growth |
| **Alerting**   | Latency-based                 | Memory threshold-based            |

**Key Insight:** JVM services can suffer without crashing - GC thrashing makes them "zombie" services that are up but unusable.

---

## Next Steps

### Extend the Use Case

1. **Combine with CPU load:**

   - Enable both `adManualGc: on` AND `adHighCpu: on`
   - Observe combined memory + CPU pressure
   - Even worse performance degradation

2. **Compare with other JVM metrics:**

   - Monitor JVM thread count
   - Track JVM heap generations (young/old)
   - Observe GC types (minor vs full GC)

3. **Test with different heap sizes:**

   - In production, you could adjust `-Xmx` flags
   - Smaller heap = more frequent GC
   - Larger heap = less frequent but longer GC

4. **Create SLO for latency:**
   - Define acceptable P95 latency (e.g., < 100ms)
   - Track error budget burn during GC thrashing
   - Demonstrate how GC impacts user experience

---

## References

- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [Honeycomb Query Language](https://docs.honeycomb.io/query-data/)
- [JVM Garbage Collection Basics](https://docs.oracle.com/en/java/javase/11/gctuning/)
- [OpenTelemetry JVM Metrics](https://opentelemetry.io/docs/specs/semconv/runtime/jvm-metrics/)

---

## Summary

This use case demonstrates **JVM garbage collection thrashing** using:

- ✅ Feature flag for dynamic control (`adManualGc`)
- ✅ Realistic JVM memory pressure scenario
- ✅ Observable in Honeycomb with latency analysis
- ✅ ZERO code changes required
- ✅ ZERO configuration changes required
- ✅ Cyclical degradation pattern (not crash)
- ✅ Trace and log correlation showing GC impact
- ✅ Dashboard with latency spikes and heap oscillation
- ✅ Alert configuration for GC-related performance issues

**Key difference from Go scenario:** This demonstrates a service that stays alive but becomes periodically unresponsive due to GC pressure - a common JVM production issue that's harder to detect than outright crashes.
