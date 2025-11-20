# Observability Patterns & Recommended Alerts

This guide covers what you can observe when infrastructure failures occur and provides recommended alerting configurations based on the OpenTelemetry Demo setup.

## Table of Contents

1. [Application Crash Observability](#application-crash-observability)
2. [DNS Failures](#dns-failures)
   - [Complete DNS Failure (0% Success)](#complete-dns-failure)
   - [DNS Capacity Issues (50-80% Success)](#dns-capacity-issues)
3. [Recommended Triggers & SLOs](#recommended-triggers--slos)

---

## Application Crash Observability

### What You Can See When Applications Crash

**Crash Methods:**
- Manual pod kill: `kubectl delete pod <pod-name>`
- OOM kill: Memory limit exceeded
- Process crash: Application error/panic
- CrashLoopBackOff: Repeated failures

### Observable Signals

#### 1. Kubernetes Events (k8s-events dataset)

```
WHERE namespace = "otel-demo"
  AND k8s.pod.name = "<pod-name>"
  AND k8s.event.reason IN ("Killing", "Started", "Created", "BackOff")
ORDER BY timestamp DESC
```

**Shows:** Crash timestamp, recovery timeline, restart attempts

#### 2. Container Termination Details

```
WHERE namespace = "otel-demo"
  AND k8s.container.last_terminated.reason EXISTS
VISUALIZE k8s.container.last_terminated.reason,
         k8s.container.last_terminated.exit_code
```

**Exit codes:**
- `137` = OOM kill (SIGKILL)
- `1` = General error
- `0` = Graceful shutdown

#### 3. Restart Count Metrics

```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY time(30s)
```

**Shows:** Crash frequency pattern (single vs repeated crashes)

#### 4. Trace Analysis

```
WHERE service.name = "checkout" AND otel.status_code = ERROR
VISUALIZE TRACES
ORDER BY timestamp DESC
```

**Look for:**
- Traces ending abruptly (no completion)
- Last span before crash
- Missing child spans

#### 5. Service Availability

```
WHERE service.name = "checkout"
VISUALIZE COUNT
GROUP BY time(10s)
```

**Shows:** Request rate drops to 0 during crash, returns on recovery

#### 6. Cascading Failures (Downstream Services)

```
WHERE service.name = "frontend"
  AND error = true
  AND (error.message CONTAINS "connection refused"
       OR error.message CONTAINS "no such host")
VISUALIZE COUNT
GROUP BY time(10s)
```

**Shows:** Impact on dependent services

---

## DNS Failures

Two distinct DNS failure scenarios with different observable patterns.

### Complete DNS Failure

Demonstrate total DNS outage by stopping CoreDNS, causing 100% service-to-service communication failures.

#### How It Works

**Stop CoreDNS:**
```bash
# Scale CoreDNS to 0 replicas
kubectl scale deployment coredns -n kube-system --replicas=0

# Verify it's stopped
kubectl get pod -n kube-system -l k8s-app=kube-dns
# Expected: No resources found
```

**⚠️ WARNING:** This affects **all pods** in the cluster. Only use in test/demo clusters.

**Generate Load:**
```bash
# Via Locust: http://localhost:8089
# Users: 10, Click "Start"

# Or manually browse: http://localhost:8080
```

**Restore:**
```bash
kubectl scale deployment coredns -n kube-system --replicas=2
```

---

#### Observable Patterns

**DNS Failure Indicators:**
- ✅ Error contains: **"lookup"**, **"no such host"**, **"name resolution"**
- ✅ **No child spans** in trace (connection never established)
- ✅ Duration = DNS timeout (~5 seconds, consistent)
- ✅ **No IP address** in error message (DNS never resolved)
- ✅ Affects **all backend services** uniformly
- ✅ **100% failure rate** (immediate)

**NOT DNS Failure (Service Down):**
- ❌ Error shows **IP address** (DNS worked, connection failed)
- ❌ Backend spans **present** but errored
- ❌ Only **specific service** fails
- ❌ **Variable latency**

---

#### Key Queries

**Frontend Error Rate:**
```
WHERE service.name = "frontend"
VISUALIZE COUNT
GROUP BY otel.status_code, time(1m)
```

**Expected:** Spike in ERROR status codes (100% failure)

**DNS Error Messages:**
```
WHERE service.name = "frontend" AND error = true
VISUALIZE COUNT
GROUP BY error.message
```

**Expected error messages:**
- `dial tcp: lookup cart: no such host`
- `dial tcp: lookup productcatalog: i/o timeout`
- `Temporary failure in name resolution`

**Trace Analysis:**
```
WHERE service.name = "frontend" AND otel.status_code = ERROR
VISUALIZE TRACES
ORDER BY timestamp DESC
LIMIT 20
```

**Look for:**
- ❌ No child spans (never reached backend)
- ❌ Error message with DNS keywords
- ❌ Duration ~5000ms (DNS timeout)
- ❌ No IP address in error

**Latency Pattern:**
```
WHERE service.name = "frontend"
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
```

**Expected:** Single latency band around 5000ms (uniform timeout)

---

#### DNS Caching Behavior

**Cache varies by runtime:**
- **Go services** (frontend, checkout, cart): Cache **indefinitely** until restart
- **Other runtimes**: Cache varies (immediate to 5 minutes)

**If services still work after stopping DNS:**
- Wait 2-5 minutes for cache to expire, OR
- Restart pods to clear cache:
  ```bash
  kubectl rollout restart deployment/frontend -n otel-demo
  kubectl rollout restart deployment/checkout -n otel-demo
  ```

---

#### Comparison: DNS Complete Failure vs Service Down

**DNS Failure:**
```
Frontend → DNS lookup: cart → TIMEOUT ❌ (5 seconds)
         → Error: "no such host"
         → No TCP connection attempted
         → No backend span ❌
```

**Service Down (NOT DNS):**
```
Frontend → DNS lookup: cart → 10.0.1.15 ✅
         → TCP connect: 10.0.1.15:8080 → REFUSED ❌
         → Error: "connection refused" (has IP address)
```

---

### DNS Capacity Issues

### How to Demonstrate DNS Overload

This scenario shows **partial DNS degradation** (50-80% success rate) vs complete failure (0%).

#### Setup Steps

**1. Scale CoreDNS UP (pre-populate cache):**
```bash
kubectl scale deployment coredns -n kube-system --replicas=10
# Run load test for 2-3 minutes with 50 users
```

**2. Scale CoreDNS DOWN (80% reduction):**
```bash
kubectl scale deployment coredns -n kube-system --replicas=2
# Keep load test running
```

#### Observable Patterns

**DNS Capacity Issue Indicators:**
- ✅ 50-80% success rate (not 0%)
- ✅ CoreDNS CPU at 95-100%
- ✅ Variable latency (three bands: fast/slow/timeout)
- ✅ P99 degrades but P50 remains OK
- ✅ Gradual failure as cache expires

### Key Queries

#### 1. Success Rate (Shows Partial Degradation)

```
WHERE service.name = frontend
  AND span.kind = "client"
VISUALIZE (COUNT WHERE otel.status_code = OK) / COUNT
GROUP BY time(1m)
```

**Expected:** 60-80% (not 0% like complete DNS failure)

#### 2. Latency Heatmap (Shows Three Bands)

```
WHERE service.name = frontend
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
```

**Bands:**
- Fast: <100ms (DNS cached)
- Slow: 1000-3000ms (DNS delayed but succeeds)
- Timeout: ~5000ms (DNS query times out)

#### 3. P50/P95/P99 Comparison

```
WHERE service.name = frontend
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(30s)
```

**Pattern:** P50 stays low, P99 spikes high = capacity issue

#### 4. CoreDNS CPU Monitoring

```
WHERE k8s.pod.name STARTS_WITH "coredns"
VISUALIZE MAX(k8s.pod.cpu_utilization)
GROUP BY time(30s)
```

**Expected:** 95-100% during capacity issues

### Timeline

| Time | CoreDNS State | Observable Behavior | Success Rate |
|------|---------------|---------------------|--------------|
| 0m | 10 replicas | All cached | 100% |
| +3m | **Scale to 2** | Still cached | 100% |
| +4m | 2 replicas | CoreDNS overloaded | 70-85% |
| +5m | 2 replicas | Mixed fail/timeout/succeed | 60-80% |
| +10m | 2 replicas | Even Go services affected | 50-70% |

### Cleanup

```bash
# Restore CoreDNS
kubectl scale deployment coredns -n kube-system --replicas=2
```

---

## Recommended Triggers & SLOs

Based on the OpenTelemetry Demo setup, here are the recommended alerting configurations.

### Alert 1: Pod OOM Kill Detected

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.event.reason = "Killing"
  AND k8s.container.last_terminated.reason = "OOMKilled"
VISUALIZE COUNT
GROUP BY k8s.pod.name, time(5m)
```

**Trigger:**
- **Threshold:** COUNT > 0
- **Frequency:** Every 1 minute
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

### Alert 2: CrashLoopBackOff

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.event.reason = "BackOff"
  AND k8s.container.restart_count > 5
VISUALIZE COUNT
GROUP BY k8s.pod.name, time(5m)
```

**Trigger:**
- **Threshold:** COUNT > 0
- **Frequency:** Every 1 minute
- **Severity:** CRITICAL

**Notification:**
```
🔴 CrashLoopBackOff Detected

Pod: {{k8s.pod.name}}
Restart Count: {{k8s.container.restart_count}}

Action: Service cannot recover - investigate root cause
```

---

### Alert 3: Service Down (No Requests)

**Query:**
```
WHERE service.name = "checkout"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** COUNT = 0 for 2 consecutive minutes
- **Frequency:** Every 1 minute
- **Severity:** CRITICAL

**Notification:**
```
🔴 Service Down

Service: checkout
No requests received for 2+ minutes

Action: Check pod status and restart events
```

---

### Alert 4: DNS Capacity Issues (Partial Failures)

**Step 1: Create Calculated Field `is_dns_error`**

```
IF(AND(
   EQUALS($span.kind,"client"),
   OR(EXISTS($http.method), EXISTS($rpc.method))
),
   IF(OR(
      CONTAINS($exception.message,"lookup"),
      CONTAINS($exception.message,"no such host"),
      CONTAINS($exception.message,"name resolution"),
      CONTAINS($error.message,"lookup"),
      CONTAINS($error.message,"no such host")
   ), 1, 0),
   null)
```

**Step 2: Create Calculated Field `dns_error_rate`**

```
DIV(SUM($is_dns_error), COUNT(WHERE $is_dns_error != null))
```

**Step 3: Create Alert Query**

```
WHERE service.name = frontend
VISUALIZE dns_error_rate
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** dns_error_rate BETWEEN 0.2 AND 0.8
- **Frequency:** Every 1 minute
- **Severity:** WARNING

**Why 0.2-0.8:** Catches partial failures (20-80%), distinguishing from complete outage (100%) or normal operation (<20%)

**Notification:**
```
⚠️ DNS Capacity Issues Detected

Service: frontend
DNS Error Rate: {{dns_error_rate}}%
Pattern: Partial failures (capacity constraint)

Action: Check CoreDNS CPU and scale if needed
```

---

### Alert 5: P99 Latency Degradation (Capacity Issue Pattern)

**Query:**
```
WHERE service.name = frontend
VISUALIZE P99(duration_ms), P50(duration_ms)
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** P99(duration_ms) > 3000 AND P50(duration_ms) < 500
- **Frequency:** Every 1 minute
- **Severity:** WARNING

**Why:** P99 high + P50 low indicates some requests slow (capacity constraint), not all requests slow

**Notification:**
```
⚠️ Tail Latency Degraded

Service: frontend
P99: {{P99(duration_ms)}}ms
P50: {{P50(duration_ms)}}ms

Pattern: Capacity issue (not all requests affected)
Action: Check for DNS issues, resource constraints, or queueing
```

---

### Alert 6: CoreDNS CPU Saturation

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "coredns"
VISUALIZE AVG(k8s.pod.cpu_utilization)
GROUP BY time(30s)
```

**Trigger:**
- **Threshold:** AVG(k8s.pod.cpu_utilization) > 0.9
- **Frequency:** Every 30 seconds
- **Severity:** CRITICAL

**Notification:**
```
🔴 CoreDNS Overloaded

CPU Utilization: {{AVG(k8s.pod.cpu_utilization)}}%

Action: Scale CoreDNS immediately
kubectl scale deployment coredns -n kube-system --replicas=<N>
```

---

### Alert 7: High Restart Rate

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY time(10m)
```

**Trigger:**
- **Threshold:** Increase > 3 restarts in 10 minutes
- **Frequency:** Every 5 minutes
- **Severity:** WARNING

**Notification:**
```
⚠️ High Restart Rate

Pod: {{k8s.pod.name}}
Restarts: {{MAX(k8s.container.restart_count)}}

Action: Service unstable - investigate crash pattern
```

---

### Alert 8: Variable Latency (DNS Queueing Pattern)

**Query:**
```
WHERE service.name = frontend
VISUALIZE STDDEV(duration_ms)
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** STDDEV(duration_ms) > 1500
- **Frequency:** Every 1 minute
- **Severity:** WARNING

**Notification:**
```
⚠️ High Latency Variance

Service: frontend
Std Dev: {{STDDEV(duration_ms)}}ms

Possible Cause: DNS queueing or intermittent failures
Action: Check DNS capacity and network issues
```

---

## SLO Recommendations

### SLO 1: Service Availability

**Target:** 99.9% of requests succeed (error rate < 0.1%)

**Query:**
```
WHERE service.name = "frontend"
  AND span.kind = "server"
CALCULATE (COUNT WHERE otel.status_code = OK) / COUNT
```

**Burn Rate Alert:** If error budget burns >10x normal rate over 1 hour

---

### SLO 2: P95 Latency

**Target:** 95% of requests complete within 500ms

**Query:**
```
WHERE service.name = "frontend"
  AND span.kind = "server"
CALCULATE P95(duration_ms)
```

**Threshold:** P95 < 500ms for 99% of time windows

---

### SLO 3: Pod Stability

**Target:** < 3 restarts per pod per day

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
CALCULATE MAX(k8s.container.restart_count)
```

**Threshold:** Daily increase < 3

---

## Dashboard Recommendations

### Crash Observability Dashboard

**Panels:**
1. Crash timeline (k8s.event.reason over time)
2. Restart count trend
3. Termination reasons breakdown
4. Service availability (request count)
5. Pre-crash memory usage
6. Cascading errors (downstream failures)

### DNS Capacity Dashboard

**Panels:**
1. Success rate over time
2. Latency heatmap (shows three bands)
3. P50/P95/P99 comparison
4. DNS error rate
5. CoreDNS CPU utilization
6. Request volume

---

## Key Takeaways

### What You CAN Observe

✅ Exact crash timestamp and reason
✅ Exit codes (OOM vs error)
✅ Restart patterns (single vs CrashLoopBackOff)
✅ Pre-crash resource metrics
✅ Trace correlation (what was happening)
✅ Cascading failures
✅ MTTR calculation
✅ DNS capacity constraints
✅ Mixed success/failure patterns
✅ Variable latency (fast/slow/timeout)

### Alert Strategy

**CRITICAL alerts** (immediate action):
- Pod OOM kills
- CrashLoopBackOff
- Service completely down
- CoreDNS CPU saturation

**WARNING alerts** (investigate soon):
- DNS partial failures (20-80% error rate)
- P99 latency degradation
- High restart rate
- High latency variance

### Production Scenarios Covered

1. **Application crashes** - OOM, errors, panics
2. **DNS capacity issues** - Undersized DNS for cluster load
3. **Cascading failures** - Downstream impact
4. **Resource exhaustion** - Memory/CPU limits
5. **Service degradation** - Partial failures vs complete outages

---

## Related Scenarios

- [memory-tracking-spike-crash.md](memory-tracking-spike-crash.md) - OOM kill demonstration
- [memory-leak-gradual-checkout.md](memory-leak-gradual-checkout.md) - Predictable crash pattern
- [jvm-gc-thrashing-ad-service.md](jvm-gc-thrashing-ad-service.md) - Zombie service
- [dns-resolution-failure.md](dns-resolution-failure.md) - Complete DNS failure (0% success)
- [istiod-crash-restart.md](istiod-crash-restart.md) - Control plane crash

---

**Last Updated:** 2025-11
**Status:** Ready for production use
