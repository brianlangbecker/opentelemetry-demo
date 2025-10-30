# Memory Spike / Sudden Crash - Checkout Service

## Overview

This guide demonstrates how to observe a **memory spike leading to an OOM crash** using the OpenTelemetry Demo's checkout service (Go), with telemetry sent to Honeycomb for analysis.

> ⚠️ **WARNING: Collateral Damage to Accounting Service**
>
> **High flag values (2000) will also crash the accounting service!**
>
> - Checkout creates N Kafka messages per order (where N = flag value)
> - Accounting service (120Mi limit) tries to consume ALL messages
> - With 2000 messages/order, accounting service OOMs in seconds
> - **Result**: Both checkout AND accounting will crash
>
> **Recommendations**:
>
> - Use **200-500** for controlled checkout-only crashes
> - Use **2000** if you want to demonstrate cascading failures
> - Monitor both services: `kubectl get pods -n otel-demo | grep -E "checkout|accounting"`

### Use Case Summary

- **Primary Target:** `checkout` (Go microservice)
- **Secondary Impact:** `accounting` (C# microservice) - **crashes with high flag values**
- **Memory Limits:** Checkout: 20Mi, Accounting: 120Mi
- **Trigger Mechanism:** Feature flag (`kafkaQueueProblems`) + Load generator
- **Observable Outcome:** Memory spike → OOM Kill → Container restart (both services with high values)
- **Pattern:** Configurable growth rate (slow/medium/fast) based on flag value
- **Monitoring:** Honeycomb UI for metrics, traces, and restart events

---

## Related Scenarios Using `kafkaQueueProblems` Flag

The same feature flag creates different failure modes depending on configuration:

| Scenario                                                   | Primary Target    | Secondary Impact    | Flag Value | Users | Observable Outcome                        |
| ---------------------------------------------------------- | ----------------- | ------------------- | ---------- | ----- | ----------------------------------------- |
| **[Memory Spike](memory-tracking-spike-crash.md)**         | Checkout (Go)     | **Accounting (C#)** | 2000       | 50    | Fast OOM crash both services (this guide) |
| **[Gradual Memory Leak](memory-leak-gradual-checkout.md)** | Checkout (Go)     | Accounting (C#)     | 200-300    | 25    | Gradual OOM in 10-20m                     |
| **[Postgres Disk/IOPS](postgres-disk-iops-pressure.md)**   | Postgres database | Accounting (C#)     | 100        | 10-15 | Disk growth + I/O pressure                |

**Key Differences:**

- This guide demonstrates **fast, sudden memory exhaustion** in **both** checkout and accounting services
- Use **200-500** for controlled checkout-only crashes
- Use **2000** for cascading failure demonstration (checkout → Kafka flood → accounting crash)
- The accounting service (120Mi) acts as a **downstream bottleneck** for high message volumes

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- Kubernetes cluster with kubectl access
- Access to Honeycomb UI
- FlagD UI accessible

---

## How It Works

When `kafkaQueueProblems` flag is enabled with high values:

### Checkout Service (Primary Crash)

1. **User completes checkout** in the demo application
2. **Checkout service** receives the order request
3. **Feature flag triggered:** Service spawns N goroutines (where N = flag value)
4. **Each goroutine** sends Kafka messages rapidly
5. **Memory allocation:** Each goroutine holds message buffers in memory
6. **Memory exhaustion:** With 2000 goroutines, memory grows from ~8Mi → 20Mi in seconds
7. **OOM Kill:** Linux kernel kills the process when it exceeds 20Mi limit
8. **Container restart:** Kubernetes/Docker restarts the crashed container

### Accounting Service (Cascading Crash with High Values)

1. **Kafka topic floods** with messages from checkout (2000 messages per order)
2. **Accounting service** (120Mi memory limit) subscribes to the Kafka topic
3. **Consumer tries to buffer** thousands of messages in memory
4. **Memory exhaustion:** With 2000 messages, accounting service OOMs in 1-2 seconds
5. **OOM Kill:** Accounting service crashes (Exit Code 137)
6. **CrashLoopBackOff:** Service repeatedly tries to start, consume messages, and crashes
7. **Pattern continues** until flag is disabled or load stops

**Growth Rate Configuration:**

- **Slow (100-200):** Checkout crashes slowly, accounting handles load
- **Medium (200-500):** Checkout crashes faster, accounting may struggle
- **Fast (2000):** **Both services crash** - checkout from goroutines, accounting from Kafka flood

**Production Analog:** Simulates goroutine leaks, unbounded message queues, downstream service exhaustion, and cascading failures.

---

## Execution Steps

### Step 1: Enable the Memory Spike Feature Flag

1. **Access FlagD UI:**

   ```
   http://localhost:4000
   ```

2. **Enable the flag:**
   - Find `kafkaQueueProblems` in the flag list
   - Click to edit/expand it
   - You'll see the **"on" variant** currently set to `100`
   - **Edit the "on" variant value** and change it to a higher number:
     - `200` - Moderate memory pressure
     - `500` - High memory pressure
     - `1000-2000` - Aggressive, nearly instant crash
   - Save changes

**What this does:** When activated, each checkout operation spawns N goroutines that send Kafka messages, causing rapid memory allocation. Higher values = faster and more reliable crash.

**Recommended values:**

- Start with `200-500` for controlled observation
- Use `1000-2000` for guaranteed rapid crash with even low checkout frequency

### Step 2: Generate Load

1. **Access Locust Load Generator:**

   ```
   http://localhost:8089
   ```

2. **Configure load test:**
   - Click **"Edit"** button
   - **Number of users (peak concurrency):** `50` (reliable) to `100` (faster crash)
   - **Ramp up:** `5` to `10` (users per second)
   - **Runtime (if available):** `10m` or `15m` to sustain load
   - **Host:** Should already be set to `http://frontend-proxy:8080`
   - Click **"Start"**

**Note:** Start with 50 users. If you try to go higher (e.g., 1000) and Locust stops spawning around 94 users, the load-generator container may be hitting its own resource limits. Stick with 50-100 users.

3. **Monitor load generation:**
   - Watch RPS (requests per second) climb
   - Observe response times
   - Look for checkout operations in the task breakdown

Watch the `STATUS` column for restarts.

### Step 3: Monitor Both Services (Critical!)

**Watch for crashes in BOTH services:**

```bash
# Monitor both checkout and accounting pods
watch -n 2 'kubectl get pods -n otel-demo | grep -E "checkout|accounting"'
```

**Expected behavior with kafkaQueueProblems: 2000:**

```
NAME                           READY   STATUS             RESTARTS      AGE
checkout-bc8884986-59rzz       1/1     Running            1 (2m ago)    5m   ← Crashed once, now running
accounting-dd696b5d-fnc5h      0/1     CrashLoopBackOff   7 (30s ago)   5m   ← Repeatedly crashing!
```

**Check OOM kills:**

```bash
# Check checkout OOM events
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=checkout | grep -A 10 "Last State"

# Check accounting OOM events
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=accounting | grep -A 10 "Last State"
```

**Both will show:**

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

### Step 4: Observe in Honeycomb UI

#### A. Checkout Memory Metrics Query

1. Go to Honeycomb UI → Your dataset
2. Create a new query:
   - **WHERE:** `k8s.pod.name` STARTS_WITH `checkout`
   - **Visualize:**
     - `MAX(k8s.pod.memory.working_set)` (Current memory usage)
     - `MAX(k8s.container.restarts)` (Restart count)
   - **Group By:** Time (e.g., 10s intervals)
   - **Time Range:** Last 15 minutes
3. **Run Query**

**Expected pattern:**

- Steady baseline ~5-8Mi
- Sudden spike approaching 20Mi (the limit) when load starts
- Drop to ~0 or low value after OOM kill
- Restart count increments
- Pattern repeats as container restarts

#### A2. Accounting Memory Metrics Query (Cascading Failure)

1. Go to Honeycomb UI → Your dataset
2. Create a new query:
   - **WHERE:** `k8s.pod.name` STARTS_WITH `accounting`
   - **Visualize:**
     - `MAX(k8s.pod.memory.working_set)` (Current memory usage)
     - `MAX(k8s.container.restarts)` (Restart count)
   - **Group By:** Time (e.g., 10s intervals)
   - **TIME RANGE:** Last 15 minutes
3. **Run Query**

**Expected pattern with flag value 2000:**

- Memory spikes to ~100-120Mi very quickly (1-2 seconds)
- Crashes immediately (Exit Code 137)
- **Restart count increases rapidly** (5, 10, 15+ restarts)
- **CrashLoopBackOff** - service can't stabilize
- This demonstrates the **downstream cascade effect** of Kafka message flooding

#### A3. Both Services Side-by-Side (Recommended)

```
WHERE k8s.pod.name STARTS_WITH checkout OR k8s.pod.name STARTS_WITH accounting
VISUALIZE MAX(k8s.pod.memory.working_set), MAX(k8s.container.restarts)
GROUP BY k8s.pod.name, time(30s)
TIME RANGE: Last 15 minutes
```

**This shows the cascading failure clearly:**

- Checkout crashes → Kafka floods → Accounting crashes repeatedly

#### B. Checkout Traces

1. Create a new query:
   - **WHERE:** `service.name` = `checkout` AND `name` = `PlaceOrder`
   - **Visualize:** `HEATMAP(duration_ms)`
   - **Group By:** Time
2. **Run Query**

**What to observe:**

- Checkout latencies increase as memory pressure grows
- Some traces may be incomplete (service crashes mid-request)
- Gap in traces during restart period

#### C. Container Events

1. Create a query for service lifecycle:
   - **WHERE:** `service.name` = `checkout`
   - **Visualize:** `COUNT`
   - **Group By:** Time (1 minute intervals)
2. **Run Query**

**Pattern:**

- High event count during normal operation
- Sudden drop (crash)
- Resume after restart

#### D. Kafka Queue Behavior

1. Query for Kafka producer events:
   - **WHERE:** `service.name` = `checkout` AND `messaging.system` = `kafka`
   - **Visualize:** `COUNT`
   - **Group By:** `messaging.kafka.producer.success`
2. **Run Query**

**Expected:**

- Burst of Kafka messages when flag is active
- Failed messages during memory pressure
- Correlates with memory spike

### Step 4: Create a Board in Honeycomb

Create a dashboard to track this scenario:

1. **Click "Boards"** → **"New Board"**
2. **Name it:** "Checkout Memory Spike Analysis"
3. **Add queries:**
   - **Panel 1:** Memory Usage Over Time
   - **Panel 2:** Checkout Request Rate
   - **Panel 3:** Checkout Latency (P50, P95, P99)
   - **Panel 4:** Kafka Message Volume
   - **Panel 5:** Error Count
4. **Save Board**

**Add markers for events:**

- Add a marker when you enable the feature flag
- Add a marker when you start the load test
- Annotations will help correlate actions with telemetry

---

## Verify OOM Kill

After observing crashes in Honeycomb and logs:

```bash
# Check if pod was OOM killed
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=checkout | grep -A 5 "OOMKilled"
```

Expected output will show OOM kill events in the pod events section.

---

## Expected Timeline

| Time | Event                         | Memory    | Honeycomb Observable   |
| ---- | ----------------------------- | --------- | ---------------------- |
| 0s   | Demo started                  | ~5-8Mi    | Baseline telemetry     |
| +30s | Flag enabled                  | ~5-8Mi    | Flag change event      |
| +40s | Load starts                   | ~8Mi      | Request rate increases |
| +50s | Checkouts begin               | ~12Mi     | Kafka bursts visible   |
| +60s | Multiple concurrent checkouts | ~18-19Mi  | Latency increases      |
| +70s | **OOM Kill**                  | **>20Mi** | **Gap in telemetry**   |
| +75s | Container restarts            | ~5Mi      | Telemetry resumes      |
| +85s | Crash loop continues          | Repeats   | Pattern visible        |

---

## Key Honeycomb Queries

### Query 1: Memory Spike Detection

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.working_set), MAX(k8s.pod.memory_limit_utilization)
GROUP BY time(10s)
TIME RANGE: Last 15 minutes
```

**Alternative - Memory Utilization:**

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory_limit_utilization)
GROUP BY time(10s)
TIME RANGE: Last 15 minutes
```

Look for values approaching 1.0 (100% utilization) before crash.

### Query 2: Checkout Performance Degradation

```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE HEATMAP(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(30s)
```

### Query 3: Service Restart Detection

```
WHERE service.name = checkout
VISUALIZE COUNT
GROUP BY time(1m)
```

### Query 4: Kafka Queue Problems

```
WHERE service.name = checkout AND messaging.system = kafka
VISUALIZE COUNT, SUM(messaging.kafka.producer.duration_ms)
GROUP BY messaging.kafka.producer.success
```

### Query 5: Error Rate Correlation

```
WHERE service.name = checkout
VISUALIZE COUNT
GROUP BY otel.status_code
```

### Query 6: Memory Pressure Analysis

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE
  MAX(k8s.pod.memory.working_set) as "Current Usage",
  MAX(k8s.container.memory_limit) as "Memory Limit"
GROUP BY time(10s)
TIME RANGE: Last 15 minutes
```

This shows how close you are to the limit before OOM kill occurs.

---

## Cleanup

### Stop the Load Test

1. Go to Locust UI: http://localhost:8089
2. Click **"Stop"** button

### Disable Feature Flag

1. Go to FlagD UI: http://localhost:4000
2. Set `kafkaQueueProblems` back to **`off`**

### Restart Both Services

To restart both services and clear the crash loop:

```bash
# Restart checkout service
kubectl rollout restart deployment checkout -n otel-demo

# Restart accounting service (if in CrashLoopBackOff)
kubectl rollout restart deployment accounting -n otel-demo
```

**Wait for both to stabilize:**

```bash
kubectl get pods -n otel-demo | grep -E "checkout|accounting"
```

Both should show `Running` with `0` or `1` restart count after cleanup.

---

## Troubleshooting

### Memory Not Spiking

**Verify flag is enabled:**

```bash
curl http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems
```

Should return: `{"value": 100}` or higher (200, 500, 1000, 2000).

**If memory stays below 70% (~14Mi):**

- Increase the flag value to 500, 1000, or 2000
- The default value of 100 may not be enough with low checkout frequency
- Higher values = more goroutines per checkout = faster memory exhaustion

**Check Kafka is running:**

```bash
kubectl get pod -n otel-demo | grep kafka
```

**Verify checkouts are happening:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout | grep -i "order placed"
```

**Check if flag is actually triggering:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout | grep -i "kafkaQueueProblems"
```

Should see: `"Warning: FeatureFlag 'kafkaQueueProblems' is activated"`

### Container Not Crashing

- Increase the flag value to 1000 or 2000
- Increase Locust users to 50 or more
- Ensure checkouts are actually happening (check logs)
- Allow more time (2-3 minutes) for memory to build up

### Accounting Service in CrashLoopBackOff

**This is expected behavior with high flag values (2000)!**

The accounting service will repeatedly crash because:

1. Kafka topic is flooded with messages from checkout
2. Accounting tries to consume all messages
3. 120Mi memory limit is exceeded in seconds
4. Service crashes, restarts, tries again → CrashLoopBackOff

**To fix:**

1. Stop the load generator (http://localhost:8089 → Stop)
2. Disable the feature flag (http://localhost:4000 → Set kafkaQueueProblems to "off")
3. Wait for Kafka messages to clear
4. Accounting service will stabilize after 1-2 minutes

**Or reduce the flag value:**

- Use **200-500** instead of 2000 to avoid accounting service crashes
- This targets only the checkout service

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **Memory growth patterns** in a real microservice (checkout)
2. ✅ **Cascading failures** from upstream to downstream services (checkout → Kafka → accounting)
3. ✅ **Feature flag impact** on resource consumption in **multiple services**
4. ✅ **OOM kill behavior** in containerized environments (both checkout and accounting)
5. ✅ **Service restart patterns** and crash loops (especially accounting's CrashLoopBackOff)
6. ✅ **Telemetry gaps** during service crashes
7. ✅ **Correlation between** load, feature flags, and resource exhaustion
8. ✅ **Downstream bottlenecks** (accounting's 120Mi limit as Kafka consumer)
9. ✅ **Honeycomb queries** for infrastructure monitoring across multiple services
10. ✅ **Distributed tracing** during degraded performance
11. ✅ **Message queue flooding** and its impact on consumers

---

## Next Steps

### Extend the Use Case

1. **Add alerts in Honeycomb:**

   - Trigger on: `MAX(process.runtime.go.mem.heap_alloc) > 15000000` (15Mi)
   - Send to: Slack, PagerDuty, etc.

2. **Monitor pod evictions:**

   - Observe pod evictions and rescheduling
   - Use `kubectl top pods` alongside Honeycomb

3. **SLO tracking:**
   - Create SLI for checkout availability
   - Track error budget burn during incidents

---

## References

- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [Honeycomb Query Language](https://docs.honeycomb.io/query-data/)
- [Go Runtime Metrics](https://opentelemetry.io/docs/specs/semconv/runtime/go-metrics/)
- [OpenTelemetry Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)

---

## Support

For issues with:

- **OpenTelemetry Demo:** https://github.com/open-telemetry/opentelemetry-demo/issues
- **Honeycomb:** https://docs.honeycomb.io or support@honeycomb.io
- **This use case:** Open an issue in this repository
