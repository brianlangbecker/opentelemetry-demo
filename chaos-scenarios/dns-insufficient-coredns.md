# DNS Capacity Issues / Insufficient CoreDNS

## Overview

This guide demonstrates how to observe **DNS capacity and performance degradation** by reducing CoreDNS instances to insufficient capacity in Kubernetes, causing mixed DNS lookup failures and slowdowns. This scenario helps identify DNS as a bottleneck vs complete failure.

### Use Case Summary

- **Target:** All services relying on DNS for service discovery
- **Infrastructure:** CoreDNS (Kubernetes DNS service)
- **Trigger Mechanism:** Scale CoreDNS UP to populate cache → Scale DOWN to insufficient capacity
- **Observable Outcome:** Mixed DNS success/failure → Variable latency → Gradual degradation as cache expires
- **Pattern:** Partial DNS availability showing capacity constraints
- **Monitoring:** Honeycomb traces showing mixed patterns, not uniform failures

---

## Related Scenarios

| Scenario | DNS State | Observable Pattern | Use Case |
|----------|-----------|-------------------|----------|
| **[DNS Complete Failure](dns-resolution-failure.md)** | 0 replicas | All DNS fails uniformly | Total DNS outage |
| **[DNS Insufficient Capacity](dns-insufficient-coredns.md)** | 1-2 replicas (80% reduction) | Mixed success/failure, variable latency | Capacity planning, overload (this guide) |

**Key Difference:** This demonstrates **DNS capacity issues and overload** rather than complete failure - showing how services degrade when DNS can't keep up with demand.

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- **Kubernetes cluster** with kubectl access and deployment scaling permissions
- Access to Honeycomb UI
- CoreDNS running (default in most Kubernetes clusters)

---

## How It Works

### DNS Capacity and Cache Behavior

1. **Normal State:**
   - CoreDNS has 2 replicas (typical default)
   - Each service queries DNS for backend service names
   - DNS cache populated: Go services cache indefinitely, others vary (30s-5min TTL)

2. **Pre-Population Phase (Scale UP):**
   - Scale CoreDNS to **10 replicas** (high capacity)
   - Generate sustained traffic for 2-3 minutes
   - All services populate DNS cache with successful lookups
   - Establishes baseline of cached DNS entries across services

3. **Capacity Reduction Phase (Scale DOWN to 20%):**
   - Scale CoreDNS to **2 replicas** (or 1 for more dramatic effect)
   - This is **80% reduction** from 10 → 2 replicas
   - CoreDNS becomes overloaded as cache expires across services
   - DNS queries queue up, causing timeouts and delays

4. **Observable Degradation Pattern:**
   - **Immediate (0-30s):** Services with cached DNS continue working normally
   - **Gradual (30s-2min):** Cache expires in some services (non-Go), DNS queries start timing out
   - **Mixed state (2-5min):** Some requests succeed (cached), some slow (queued), some fail (timeout)
   - **Go services last (5+ min):** Go services cache indefinitely, eventually fail when connections break

### Why This Differs From Complete Failure

| Aspect | Complete Failure (0 replicas) | Insufficient Capacity (1-2 replicas) |
|--------|------------------------------|-------------------------------------|
| **DNS Available** | No | Yes, but overloaded |
| **Pattern** | Uniform failures | Mixed success/failure/slow |
| **Latency** | Fixed timeout (~5s) | Variable (50ms → 5000ms) |
| **Cache Impact** | Cache helps temporarily | Cache masks problem initially |
| **CoreDNS CPU** | N/A | Very high (95-100%) |
| **Real-world** | DNS service down | DNS undersized for load |

**Production Analog:** Simulates DNS capacity planning issues, traffic spikes overwhelming DNS, or insufficient DNS replicas for cluster size.

---

## Execution Steps

### Step 1: Check CoreDNS Baseline

```bash
# Check current CoreDNS replica count
kubectl get deployment -n kube-system coredns

# Expected output:
# NAME      READY   UP-TO-DATE   AVAILABLE   AGE
# coredns   2/2     2            2           45d
```

**Save this number** - you'll restore to this count later.

### Step 2: Verify Services Working (Baseline)

```bash
# Check all demo services are running
kubectl get pod -n otel-demo

# Test frontend can reach cart service
kubectl exec -n otel-demo deployment/frontend -- wget -O- -T 5 http://cart:8080/health

# Expected output: HTTP 200 OK
```

**Access Honeycomb UI to view baseline traces:**
```
https://ui.honeycomb.io
```

Open your frontend traces view:
```
WHERE service.name = frontend
VISUALIZE TRACES
TIME RANGE: Last 15 minutes
```

### Step 3: Scale CoreDNS UP (Pre-populate Cache)

**⚠️ CRITICAL STEP:** This pre-populates DNS cache across all services to show realistic cache expiration behavior.

```bash
# Scale CoreDNS UP to 10 replicas (high capacity)
kubectl scale deployment coredns -n kube-system --replicas=10

# Verify all replicas are running
kubectl get pod -n kube-system -l k8s-app=kube-dns

# Expected output:
# NAME                       READY   STATUS    RESTARTS   AGE
# coredns-565d847f94-xxxxx   1/1     Running   0          10s
# coredns-565d847f94-xxxxx   1/1     Running   0          10s
# ... (10 total pods)
```

**Why this step matters:**
- Ensures DNS resolution works perfectly initially
- Populates DNS cache across all services (including Go services)
- Makes the degradation pattern more realistic and observable

### Step 4: Generate Sustained Traffic (Populate Cache)

**Access Locust Load Generator:**
```
http://localhost:8089
```

**Configure load test:**
- **Number of users:** `50`
- **Ramp up:** `5`
- **Runtime:** `3m` (3 minutes to populate cache)
- Click **"Start"**

**What this does:**
- Generates traffic across all services
- DNS lookups happen and get cached
- Establishes baseline traffic patterns
- All services now have warm DNS cache

**Let this run for 2-3 minutes** before proceeding.

### Step 5: Scale CoreDNS DOWN (80% Reduction)

**⚠️ WARNING:** This will cause DNS capacity issues across the cluster. Only do this in test/demo clusters.

```bash
# Scale CoreDNS DOWN to 2 replicas (80% reduction from 10)
kubectl scale deployment coredns -n kube-system --replicas=2

# For more dramatic effect, scale to 1 replica (90% reduction)
kubectl scale deployment coredns -n kube-system --replicas=1

# Verify reduced capacity
kubectl get pod -n kube-system -l k8s-app=kube-dns

# Expected output:
# NAME                       READY   STATUS    RESTARTS   AGE
# coredns-565d847f94-abc12   1/1     Running   0          45d
# coredns-565d847f94-def34   1/1     Running   0          45d
```

**Keep load test running** to continue generating traffic and DNS queries.

### Step 6: Observe DNS Capacity Issues

**Watch CoreDNS CPU (should spike to 95-100%):**

```bash
kubectl top pod -n kube-system -l k8s-app=kube-dns

# Expected pattern:
# NAME                       CPU     MEMORY
# coredns-565d847f94-abc12   950m    25Mi    ← Very high CPU!
# coredns-565d847f94-def34   920m    23Mi    ← Overloaded!
```

**Check CoreDNS logs for query volume:**

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50 --prefix

# Look for:
# - High query rate
# - Potential timeout messages
# - Cache miss patterns
```

**Observe frontend service errors (mixed pattern):**

```bash
kubectl logs -n otel-demo deployment/frontend --tail=50 | grep -i "dns\|no such host\|lookup\|timeout"

# Expected: Mix of successful and failed DNS lookups
```

### Step 7: Observe in Honeycomb UI

**Open Honeycomb UI:** `https://ui.honeycomb.io`

#### Query 1: Frontend Error Rate (Should Show Mixed Pattern)

```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY otel.status_code, time(30s)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **Before scaling down (0-3min):** All requests OK
- **After scaling down (3-10min):** Mix of OK and ERROR statuses
- **Pattern:** Not 100% errors (unlike complete DNS failure)

#### Query 2: Request Latency Distribution

```
WHERE service.name = frontend
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **Variable latency bands:** Some fast (cached), some slow (queued DNS), some timeout (5000ms)
- **Not uniform:** Unlike complete failure, shows mixed performance
- **Three distinct bands:**
  - Fast: <100ms (DNS cached)
  - Slow: 1000-3000ms (DNS delayed but succeeds)
  - Timeout: ~5000ms (DNS query times out)

#### Query 3: P50/P95/P99 Latency Over Time

```
WHERE service.name = frontend
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(30s)
TIME RANGE: Last 15 minutes
```

**Expected pattern:**
- **P50 (median):** Remains relatively low (many cached lookups succeed)
- **P95:** Increases significantly (some DNS delays)
- **P99:** Spikes to timeout values (worst-case DNS failures)

**This shows:** Most users have OK experience, but some hit DNS capacity limits.

#### Query 4: DNS Error Message Analysis

```
WHERE service.name = frontend AND error = true
VISUALIZE COUNT
GROUP BY error.message
TIME RANGE: Last 15 minutes
```

**Expected error messages (examples - format varies by language):**
- `dial tcp: lookup cart: i/o timeout` ← DNS timeout
- `context deadline exceeded` ← Request timeout due to DNS delay
- `no such host` ← DNS query failed

**Note:** Mix of timeout and resolution errors, not just "no such host".

#### Query 5: Success Rate Degradation (Outbound Calls Only)

```
WHERE service.name = frontend
  AND span.kind = "client"
VISUALIZE (COUNT WHERE otel.status_code = OK) / COUNT
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected pattern:**
- **Before:** 100% success rate
- **After scaling down:** 60-80% success rate (not 0% like complete failure)
- **Shows partial degradation** vs complete outage

**Why filter to client spans:** Only outbound service calls require DNS resolution. This excludes server spans (incoming requests) and internal operations that wouldn't be affected by DNS issues.

---

## Expected Timeline

| Time | CoreDNS State | Cache Status | Observable Behavior | Success Rate |
|------|---------------|--------------|---------------------|--------------|
| 0m | 2 replicas (baseline) | Cold | Some cache misses | 95-100% |
| +0s | Scale UP to 10 | Warming | DNS very fast | 100% |
| +2m | 10 replicas | Hot | All cached | 100% |
| +3m | **Scale DOWN to 2** | Hot | Still cached | 100% |
| +3m 30s | 2 replicas | Expiring | Cache expiring in non-Go services | 95-98% |
| +4m | 2 replicas | **Partial** | CoreDNS overloaded, queries queuing | 70-85% |
| +5m | 2 replicas | **Mixed** | Some fail, some timeout, some succeed | 60-80% |
| +7m | 2 replicas | Mostly expired | Go services still cached, others struggling | 60-75% |
| +10m | 2 replicas | Critical | Even Go services hitting DNS issues | 50-70% |

**Key Observation:** Unlike complete DNS failure (0% success rate immediately), this shows **gradual degradation** to 50-80% success rate.

---

## Honeycomb Dashboard Configuration

Create a board named **"DNS Capacity Issues Analysis"** with these panels:

### Panel 1: Success Rate Over Time
```
WHERE service.name = frontend
VISUALIZE (COUNT WHERE otel.status_code = OK) / COUNT
GROUP BY time(1m)
```

### Panel 2: Latency Heatmap (Shows Three Bands)
```
WHERE service.name = frontend
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
```

### Panel 3: P50/P95/P99 Latency
```
WHERE service.name = frontend
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(30s)
```

### Panel 4: Error Rate by Type
```
WHERE service.name = frontend AND error = true
VISUALIZE COUNT
GROUP BY error.message
```

### Panel 5: Request Volume
```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY time(30s)
```

### Panel 6: Error Distribution
```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY otel.status_code
```

---

## Comparison: Complete Failure vs Insufficient Capacity

| Indicator | Complete DNS Failure (0 replicas) | Insufficient Capacity (1-2 replicas) |
|-----------|----------------------------------|-------------------------------------|
| **Success Rate** | 0% (immediate) | 50-80% (gradual) |
| **Latency Pattern** | Fixed timeout (~5000ms) | Variable (100ms → 5000ms) |
| **Error Messages** | "no such host" uniform | Mix of timeout, "no such host", deadline exceeded |
| **Cache Impact** | Masks briefly, then all fail | Significantly extends service availability |
| **CoreDNS CPU** | N/A | 95-100% (overloaded) |
| **Observable in Heatmap** | Single timeout band | **Three distinct bands** (fast/slow/timeout) |
| **User Impact** | All users affected | **Partial users affected** |
| **Production Scenario** | DNS service down | **DNS undersized for load** |

**Critical Difference:** Insufficient capacity shows **partial degradation with mixed patterns**, while complete failure shows **uniform immediate failure**.

---

## Key Observability Patterns

### DNS Capacity Issue Indicators:

✅ **Mixed success/failure** (not 100% failure)
✅ **Variable latency** (fast cached → slow queued → timeout)
✅ **CoreDNS CPU at 95-100%** (overloaded, not absent)
✅ **P50 stays reasonable, P99 degrades** (most succeed, tail fails)
✅ **Three distinct latency bands** in heatmap
✅ **Gradual degradation** over minutes as cache expires

### This is NOT a capacity issue if you see:

❌ 100% failure rate (that's complete DNS failure)
❌ Fixed latency at ~5000ms (uniform timeout = DNS down)
❌ No CoreDNS CPU metrics (DNS service not running)
❌ Immediate failure (no gradual pattern)

---

## Cleanup / Restore DNS Capacity

### Restore CoreDNS to Original Capacity

```bash
# Restore CoreDNS to original replica count (usually 2)
kubectl scale deployment coredns -n kube-system --replicas=2

# Or if you noted a different baseline:
kubectl scale deployment coredns -n kube-system --replicas=<ORIGINAL_COUNT>

# Verify CoreDNS is running normally
kubectl get pod -n kube-system -l k8s-app=kube-dns

# Expected output:
# NAME                       READY   STATUS    RESTARTS   AGE
# coredns-565d847f94-abc12   1/1     Running   0          45d
# coredns-565d847f94-def34   1/1     Running   0          45d
```

### Verify DNS Resolution Restored

```bash
# Test DNS lookup from a demo pod
kubectl exec -n otel-demo deployment/frontend -- nslookup cart

# Expected output:
# Server:    10.96.0.10
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
#
# Name:      cart
# Address 1: 10.0.1.15 cart.otel-demo.svc.cluster.local
```

### Verify Services Work Again

```bash
# Test frontend can reach cart
kubectl exec -n otel-demo deployment/frontend -- wget -O- -T 5 http://cart:8080/health
```

**Verify in Honeycomb:**
- Open Honeycomb UI: `https://ui.honeycomb.io`
- Check frontend traces - should show 95-100% success rate
- Latency should return to baseline (P95 < 200ms)

### Stop Load Test

1. Go to Locust UI: http://localhost:8089
2. Click **"Stop"** button

---

## Troubleshooting

### Not Seeing Capacity Issues

**Check CoreDNS CPU:**
```bash
kubectl top pod -n kube-system -l k8s-app=kube-dns

# If CPU is NOT high (< 50%), try:
```

**Increase load:**
- Raise Locust users from 50 to 75 or 100
- More concurrent requests = more DNS queries

**Scale CoreDNS even lower:**
```bash
# Scale to 1 replica for more dramatic capacity constraint
kubectl scale deployment coredns -n kube-system --replicas=1
```

**Check DNS query rate:**
```bash
# Watch CoreDNS logs for query volume
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100 | grep -i query
```

### Still Seeing 100% Success Rate

**DNS cache may not be expiring:**

**Force cache expiry by restarting services:**
```bash
# Restart frontend to clear Go's indefinite DNS cache
kubectl rollout restart deployment/frontend -n otel-demo
kubectl rollout restart deployment/checkout -n otel-demo
kubectl rollout restart deployment/cart -n otel-demo

# Wait 30s, then continue observing
```

**Or wait longer:**
- Go services cache DNS indefinitely
- May take 5-10 minutes for connections to break
- Non-Go services should fail within 1-2 minutes

### Cluster Becomes Unstable

**CoreDNS is critical infrastructure!**

**Immediately restore CoreDNS:**
```bash
kubectl scale deployment coredns -n kube-system --replicas=2
```

**Best practice:** Only do this in:
- Dedicated demo/test clusters
- Clusters you can rebuild
- Clusters not running critical workloads

---

## Alert Configuration

### Alert 1: High DNS Error Rate (But Not 100%)

**Step 1: Create Calculated Field (Derived Column)**

In Honeycomb, create a calculated field named `is_dns_eligible`:

**Formula:**
```
IF(AND(
   EQUALS($span.kind,"client"),
   OR(
      EXISTS($http.method),
      EXISTS($rpc.method),
      EXISTS($http.url),
      EXISTS($url.full)
   )
), 1, null)
```

**What this does:**
- **HTTP/gRPC client spans:** Returns `1` (these require DNS resolution)
- **Other spans:** Returns `null` (excluded - database, Kafka, internal ops don't use DNS)

**Then create a second calculated field `is_dns_error`:**

**Formula:**
```
IF(AND(
   $is_dns_eligible = 1,
   OR(
      CONTAINS($exception.message,"lookup"),
      CONTAINS($exception.message,"no such host"),
      CONTAINS($exception.message,"name resolution")
   )
), 1, IF($is_dns_eligible = 1, 0, null))
```

**What this does:**
- **DNS-eligible spans with DNS errors:** Returns `1`
- **DNS-eligible spans without DNS errors:** Returns `0`
- **Non-DNS-eligible spans:** Returns `null` (excluded)

**Alternative (if using `error.message` instead of `exception.message`):**
```
IF(AND(
   $is_dns_eligible = 1,
   OR(
      CONTAINS($error.message,"lookup"),
      CONTAINS($error.message,"no such host"),
      CONTAINS($error.message,"name resolution")
   )
), 1, IF($is_dns_eligible = 1, 0, null))
```

**Then create a third calculated field `dns_error_rate`:**

**Formula:**
```
DIV(SUM($is_dns_error), COUNT(WHERE $is_dns_eligible = 1))
```

**What this does:**
- **Numerator:** Sum of `is_dns_error` (counts DNS errors on eligible spans)
- **Denominator:** Count of all DNS-eligible spans (HTTP/gRPC client calls)
- **Result:** Error rate between 0.0 (0%) and 1.0 (100%)

**Step 2: Create Query for Alert**

**Query (using calculated field):**
```
WHERE service.name = frontend
VISUALIZE dns_error_rate
GROUP BY time(1m)
```

**Or calculate directly in query:**
```
WHERE service.name = frontend
VISUALIZE DIV(
  SUM(is_dns_error), 
  COUNT(WHERE is_dns_eligible = 1)
)
GROUP BY time(1m)
```

**Why this approach:**
- `is_dns_eligible` filters to only HTTP/gRPC client spans (excludes database, Kafka, internal ops)
- `is_dns_error` marks DNS errors on eligible spans only
- Rate calculation only includes spans that could potentially have DNS issues
- No need to filter in WHERE clause - the calculated fields handle it

**Step 3: Create Trigger**

- **Name:** DNS Capacity Issues (Partial Failures)
- **Frequency:** 60 seconds (1 minute)
- **Threshold:** `dns_error_rate BETWEEN 0.2 AND 0.8`
- **Alert Type:** `on_true`
- **Severity:** WARNING

**Why 0.2-0.8:** Catches **partial failures** (20-80% error rate), distinguishes from complete outage (100% error rate) or normal operation (<20% error rate).

**Why filter to client spans:** Only outbound service calls require DNS resolution. Server spans (incoming requests) and internal operations (database queries, in-memory processing) are not affected by DNS issues.

### Alert 2: P99 Latency Degradation

```
TRIGGER: P99(duration_ms) > 3000 AND P50(duration_ms) < 500
WHERE: service.name = frontend
FREQUENCY: Every 1 minute
ACTION: Warning - Tail latency degraded (capacity issue pattern)
```

**Why P99 high but P50 low:** Indicates **some requests slow**, typical of capacity constraints.

### Alert 3: CoreDNS CPU Saturation

```
TRIGGER: AVG(k8s.pod.cpu_utilization) > 0.9
WHERE: k8s.pod.name STARTS_WITH coredns
FREQUENCY: Every 30 seconds
ACTION: Critical - CoreDNS overloaded
```

### Alert 4: Variable Latency Pattern

```
TRIGGER: STDDEV(duration_ms) > 1500
WHERE: service.name = frontend
FREQUENCY: Every 1 minute
ACTION: Warning - High latency variance (possible DNS queueing)
```

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **DNS capacity constraints** and overload patterns
2. ✅ **Gradual degradation** vs complete failure
3. ✅ **Mixed success/failure patterns** in traces
4. ✅ **Variable latency** from DNS queueing (fast cached → slow queued → timeout)
5. ✅ **CoreDNS CPU saturation** under load
6. ✅ **Cache expiration behavior** across different runtimes (Go vs others)
7. ✅ **Tail latency degradation** (P99 >> P50)
8. ✅ **Partial user impact** vs all users affected
9. ✅ **Capacity planning indicators** for DNS sizing

---

## Production Scenarios Simulated

This demo replicates these real-world issues:

1. **DNS Undersized for Cluster** - Not enough CoreDNS replicas for pod count
2. **Traffic Spike** - Sudden increase in service-to-service calls overwhelming DNS
3. **DNS Autoscaling Lag** - HPA not scaling DNS fast enough
4. **Cache TTL Issues** - DNS cache expiring too quickly under load
5. **DNS Query Storm** - Thundering herd after DNS cache expires
6. **Partial DNS Availability** - Some DNS queries succeed, others timeout

---

## Key Takeaways

### For Capacity Planning

**DNS Capacity Issue Indicators:**
- ✅ **50-80% success rate** (not 0%)
- ✅ **CoreDNS CPU at 95-100%**
- ✅ **Variable latency** (three distinct bands in heatmap)
- ✅ **P99 degrades but P50 remains OK**
- ✅ **Gradual failure** as cache expires

**Capacity Planning Rules:**
- **Rule of thumb:** 1 CoreDNS replica per 50-100 pods (varies by query rate)
- **Monitor:** CoreDNS CPU should stay < 70% under normal load
- **Horizontal Pod Autoscaler:** Configure HPA for CoreDNS based on CPU
- **Cache tuning:** Longer TTL reduces DNS query rate

### For Observability

- **Heatmaps reveal capacity issues:** Three bands (fast/slow/timeout) vs single band (complete failure)
- **Percentile comparison critical:** P50 OK + P99 high = capacity issue
- **Error rate alone insufficient:** Must analyze latency distribution
- **CoreDNS metrics essential:** CPU/memory/query rate for root cause

### For SREs/Platform Engineers

- **DNS is shared resource:** One team's traffic spike affects all services
- **Cache buys time:** DNS cache masks capacity issues temporarily
- **Go services special:** Cache indefinitely, last to fail
- **Partial degradation harder to detect:** Not an obvious outage

---

## Comparison Table: DNS Scenarios

| Aspect | Complete Failure (0 replicas) | Insufficient Capacity (1-2 replicas) |
|--------|------------------------------|-------------------------------------|
| **What it simulates** | DNS service down | DNS undersized for load |
| **Success rate** | 0% | 50-80% |
| **Latency pattern** | Fixed timeout | Variable (fast/slow/timeout) |
| **CoreDNS CPU** | N/A | 95-100% |
| **User impact** | All users | Partial users |
| **Detection difficulty** | Easy (obvious) | **Harder (gradual)** |
| **Production frequency** | Rare | **Common** |
| **Heatmap pattern** | Single timeout band | **Three bands** |
| **P50 vs P99** | Both high | P50 OK, **P99 high** |

---

## Next Steps

### Extend the Use Case

1. **Test different replica ratios:**
   - 10 → 5 (50% reduction): Mild capacity issues
   - 10 → 3 (70% reduction): Moderate capacity issues
   - 10 → 2 (80% reduction): Severe capacity issues
   - 10 → 1 (90% reduction): Critical capacity issues

2. **Test with different traffic levels:**
   - 25 users: Mild DNS load
   - 50 users: Moderate DNS load
   - 100 users: High DNS load

3. **Configure CoreDNS HPA:**
   ```bash
   kubectl autoscale deployment coredns -n kube-system --cpu-percent=70 --min=2 --max=10
   ```
   Observe HPA responding to load

4. **Tune DNS cache TTL:**
   - Modify CoreDNS ConfigMap
   - Increase TTL to reduce query rate
   - Observe impact on query volume

5. **Compare cache behavior:**
   - Monitor Go services (cache indefinitely)
   - Monitor Node.js services (vary by library)
   - Monitor Python services (no cache)

---

## References

- [Kubernetes DNS Specification](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [CoreDNS Documentation](https://coredns.io/manual/toc/)
- [CoreDNS Performance Tuning](https://coredns.io/2018/11/27/cluster-dns-coredns-vs-kube-dns/)
- [Kubernetes DNS Horizontal Autoscaling](https://kubernetes.io/docs/tasks/administer-cluster/dns-horizontal-autoscaling/)
- [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)

---

## Summary

This use case demonstrates **DNS capacity issues and insufficient CoreDNS instances** using:

- ✅ Zero code changes required
- ✅ Kubernetes infrastructure manipulation (CoreDNS scaling)
- ✅ Observable in Honeycomb with **mixed patterns** (not uniform failures)
- ✅ **Three distinct latency bands** in heatmap (fast/slow/timeout)
- ✅ **CoreDNS CPU saturation** at 95-100%
- ✅ **Gradual degradation** as DNS cache expires
- ✅ **Partial user impact** (50-80% success rate)
- ✅ Dashboard showing capacity constraint patterns
- ✅ Alerts for tail latency and variable latency
- ✅ Production-realistic DNS capacity planning scenario

**Key difference from complete DNS failure:** This demonstrates **DNS overload and capacity constraints** with **mixed success/failure patterns and variable latency**, vs complete outage with uniform failures. Shows how to size CoreDNS for cluster load.

**Critical Diagnostic Pattern:** If traces show **variable latency with three distinct bands** (fast cached → slow queued → timeout) AND **CoreDNS CPU at 95-100%** AND **50-80% success rate**, it's a DNS capacity issue, not complete DNS failure.
