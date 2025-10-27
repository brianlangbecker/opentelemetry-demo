# DNS Resolution Failure - Service Discovery Breakdown

## Overview

This guide demonstrates how to observe **DNS resolution failures** by stopping CoreDNS in Kubernetes, causing service-to-service communication to fail. This scenario helps isolate DNS latency and failures as the root cause, distinguishing them from application or database issues.

### Use Case Summary

- **Target:** All services relying on DNS for service discovery (especially frontend)
- **Infrastructure:** CoreDNS (Kubernetes DNS service)
- **Trigger Mechanism:** Scale CoreDNS deployment to 0 replicas
- **Observable Outcome:** DNS lookup failures → Service timeouts → Failed traces with DNS errors
- **Pattern:** Cascading failures across all services attempting DNS resolution
- **Monitoring:** Honeycomb traces showing DNS resolution errors, not application errors

---

## Related Scenarios

| Scenario | Root Cause | Observable Pattern |
|----------|------------|-------------------|
| **DNS Failure** (this guide) | DNS service down | DNS lookup errors, immediate timeouts |
| **Database Failure** | Database down | Connection errors after DNS succeeds |
| **Application Crash** | Service pod down | DNS succeeds, connection refused |
| **Network Latency** | Network issues | DNS succeeds, slow connection time |

**Key Differentiator:** DNS failures show **name resolution errors** before any network connection is attempted.

---

## Prerequisites

- OpenTelemetry Demo running with telemetry configured to send to Honeycomb
- **Kubernetes cluster** with kubectl access and deployment scaling permissions
- Access to Honeycomb UI
- CoreDNS running (default in most Kubernetes clusters)

**Note:** This scenario is **Kubernetes-only**. Docker Compose uses Docker's internal DNS which cannot be easily disabled without breaking the entire stack.

---

## How It Works

### Service Discovery in Kubernetes

1. **Frontend** calls backend services by name:
   - `http://cart:8080/api/cart`
   - `http://productcatalog:8080/api/products`
   - `http://currency:8080/api/convert`
   - `http://checkout:8080/api/checkout`

2. **DNS Resolution Process:**
   - Application makes HTTP request to `cart:8080`
   - Container queries `/etc/resolv.conf` → points to CoreDNS
   - CoreDNS resolves `cart` → `cart.otel-demo.svc.cluster.local` → Pod IP
   - Connection established to Pod IP

3. **When CoreDNS is Down:**
   - Application makes HTTP request to `cart:8080`
   - **If cached:** Uses cached IP address, connection may succeed (depends on runtime)
   - **If not cached:** DNS lookup sent to CoreDNS (no response)
   - DNS timeout after ~5 seconds (default)
   - Error: `no such host` or `temporary failure in name resolution`
   - **No network connection is attempted**
   - Request fails immediately after DNS timeout

**Important DNS Caching Behavior:**
- **Go services** (frontend, checkout, cart): Go's default DNS resolver caches successful lookups **indefinitely** until the process restarts. This means Go services may continue working for a long time after CoreDNS stops.
- **Node.js services**: Caching depends on the DNS library used (some cache, some don't)
- **Java services**: Controlled by `networkaddress.cache.ttl` (default varies by JDK version)
- **Python/Ruby services**: Typically rely on OS-level DNS resolution (no application cache)

### Observable Differences

| Failure Type | DNS Lookup | TCP Connection | Application Response | Error Message |
|--------------|------------|----------------|---------------------|---------------|
| **DNS Down** | ❌ Fails | N/A (never attempted) | N/A | `no such host`, `dial tcp: lookup cart: no such host` |
| **Service Down** | ✅ Succeeds | ❌ Fails | N/A | `connection refused`, `dial tcp 10.0.1.5:8080: connect: connection refused` |
| **Database Down** | ✅ Succeeds | ✅ Succeeds | ❌ Fails | `connection to database failed`, `SQLSTATE 08006` |
| **App Error** | ✅ Succeeds | ✅ Succeeds | ✅ Returns error | `HTTP 500`, `internal server error` |

---

## Execution Steps

### Step 1: Verify CoreDNS is Running

```bash
# Check CoreDNS status
kubectl get deployment -n kube-system coredns

# Expected output:
# NAME      READY   UP-TO-DATE   AVAILABLE   AGE
# coredns   2/2     2            2           45d
```

```bash
# Check CoreDNS pods
kubectl get pod -n kube-system -l k8s-app=kube-dns

# Expected output:
# NAME                       READY   STATUS    RESTARTS   AGE
# coredns-565d847f94-abc12   1/1     Running   0          45d
# coredns-565d847f94-def34   1/1     Running   0          45d
```

**Note:** CoreDNS might be in namespace `kube-system` and labeled `k8s-app=kube-dns`.

### Step 2: Verify Services Are Working (Baseline)

Before breaking DNS, verify everything works:

```bash
# Check all demo services are running
kubectl get pod -n otel-demo

# Test frontend can reach cart service
kubectl exec -n otel-demo deployment/frontend -- wget -O- -T 5 http://cart:8080/health

# Expected output: HTTP 200 OK or health check response
```

**Access Honeycomb UI to view traces:**
```
https://ui.honeycomb.io
```

Open your frontend traces view to monitor baseline traffic:
```
WHERE service.name = frontend
VISUALIZE TRACES
TIME RANGE: Last 15 minutes
```

Browse the demo UI (`http://localhost:8080`) to generate baseline traces by viewing products and adding items to cart.

### Step 3: Start Monitoring in Honeycomb

**Before stopping DNS**, open Honeycomb and create a query to monitor in real-time:

```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY otel.status_code
TIME RANGE: Last 15 minutes
```

Keep this query open to watch the transition from healthy to DNS failures.

### Step 4: Stop CoreDNS (Break DNS Resolution)

**⚠️ WARNING:** This will affect **all pods in the cluster** that need DNS resolution. Only do this in a test/demo cluster.

```bash
# Scale CoreDNS to 0 replicas
kubectl scale deployment coredns -n kube-system --replicas=0

# Verify CoreDNS is stopped
kubectl get pod -n kube-system -l k8s-app=kube-dns

# Expected output: No resources found
```

**Alternative (if CoreDNS is a different deployment name):**

```bash
# Find CoreDNS deployment
kubectl get deployment -n kube-system | grep dns

# Scale it to 0
kubectl scale deployment <coredns-deployment-name> -n kube-system --replicas=0
```

### Step 5: Generate Load to Trigger DNS Failures

**Access Locust Load Generator:**
```
http://localhost:8089
```

**Configure load test:**
- **Number of users:** `10` (moderate - just need to trigger requests)
- **Ramp up:** `2`
- **Runtime:** `5m`
- Click **"Start"**

**Or manually browse the demo:**
- Try to view products: `http://localhost:8080`
- Try to add items to cart
- Try to checkout

**Expected behavior:**
- Pages fail to load or show errors
- Services unreachable errors
- Long timeouts (5+ seconds per DNS lookup)

**View failures in Honeycomb traces:**
- Open Honeycomb UI: `https://ui.honeycomb.io`
- Navigate to your frontend traces view
- You should immediately see error traces appearing

### Step 6: Observe DNS Failures in Real-Time

**Check frontend logs for DNS errors:**

```bash
kubectl logs -n otel-demo deployment/frontend --tail=50 | grep -i "dns\|no such host\|lookup"
```

**Expected errors (examples - actual messages may vary by language/runtime):**
```
Error: dial tcp: lookup cart on 10.96.0.10:53: no such host
Error: dial tcp: lookup productcatalog: i/o timeout
Error: Get "http://currency:8080": dial tcp: lookup currency: Temporary failure in name resolution
```

**Note:** Error message formats vary depending on the programming language and HTTP client library. The key indicators are:
- Presence of **"lookup"**, **"no such host"**, or **"name resolution"** keywords
- Reference to DNS server IP (e.g., `10.96.0.10:53`)
- Service name without IP address (DNS never resolved)

**Check if services can resolve each other:**

```bash
# Try DNS lookup from frontend pod
kubectl exec -n otel-demo deployment/frontend -- nslookup cart

# Expected error:
# Server:    10.96.0.10
# Address 1: 10.96.0.10
#
# nslookup: can't resolve 'cart': Name or service not known
```

---

## Honeycomb Queries for DNS Failures

### Query 1: Frontend Error Rate (Primary Indicator)

```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY otel.status_code
TIME RANGE: Last 15 minutes
```

**What to look for:**
- Spike in `ERROR` status codes after DNS is stopped
- Transition from mostly `OK` to mostly `ERROR`
- Clear timeline showing when DNS was disabled

### Query 2: Frontend Request Traces (DNS Error Details)

```
WHERE service.name = frontend AND otel.status_code = ERROR
VISUALIZE TRACES
ORDER BY timestamp DESC
LIMIT 20
TIME RANGE: Last 15 minutes
```

**Click on a trace to see:**
- Span showing HTTP request to backend service
- Error message: `dial tcp: lookup cart: no such host`
- **No child spans** (never reached the backend service)
- Duration: ~5 seconds (DNS timeout)

### Query 3: DNS Error Message Analysis

```
WHERE service.name = frontend AND error = true
VISUALIZE COUNT
GROUP BY error.message
TIME RANGE: Last 15 minutes
```

**Expected error messages (examples - actual format varies by language/runtime):**
- `dial tcp: lookup cart: no such host`
- `dial tcp: lookup productcatalog: i/o timeout`
- `Get "http://currency:8080": dial tcp: lookup currency: Temporary failure in name resolution`

**Note:** The exact error message format depends on the programming language (Go, Node.js, Python, Java, etc.) and HTTP client library. Look for these **key indicators** rather than exact text matches:
- Contains **"lookup"**, **"no such host"**, or **"name resolution"**
- Shows DNS server IP if present (e.g., `on 10.96.0.10:53`)
- Shows service **name** (not IP address)

### Query 4: Service Dependency Breakdown

```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY name, otel.status_code
TIME RANGE: Last 15 minutes
```

**What to look for:**
- All backend service calls failing (cart, productcatalog, currency, checkout, shipping)
- DNS errors affecting **all** service-to-service calls uniformly

### Query 5: Request Latency Distribution

```
WHERE service.name = frontend
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
TIME RANGE: Last 15 minutes
```

**What to look for:**
- Latency band around 5000ms (5 seconds - DNS timeout)
- All requests clustering around same timeout duration
- Indicates systematic DNS issue, not random application slowness

### Query 6: Frontend Error Rate Over Time

```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY time(30s), otel.status_code
TIME RANGE: Last 15 minutes
```

**Pattern:**
- Baseline: mostly OK status
- After DNS stopped: 100% ERROR status
- After DNS restored: recovery to OK status

### Query 7: Successful vs Failed Services

```
WHERE service.name = frontend AND name STARTS_WITH "GET"
VISUALIZE COUNT
GROUP BY name, otel.status_code
TIME RANGE: Last 15 minutes
```

**What to look for:**
- Static assets (served by frontend itself): ✅ Still work
- Backend service calls (require DNS): ❌ All fail

### Query 8: DNS Resolution Time (if instrumented)

```
WHERE service.name = frontend AND span.kind = CLIENT
VISUALIZE P95(dns.lookup.duration_ms), P99(dns.lookup.duration_ms)
GROUP BY time(30s)
TIME RANGE: Last 15 minutes
```

**Note:** Only available if DNS metrics are instrumented. Most languages don't expose this by default.

### Query 9: Trace Completeness Analysis

```
WHERE trace.parent_id = null AND service.name = frontend
VISUALIZE COUNT
GROUP BY has_children
TIME RANGE: Last 15 minutes
```

**What to look for:**
- Before DNS failure: traces have children (backend spans)
- After DNS failure: traces have NO children (never reached backends)

### Query 10: Correlated Service Failures

```
WHERE otel.status_code = ERROR
VISUALIZE COUNT
GROUP BY service.name
TIME RANGE: Last 15 minutes
```

**What to look for:**
- **Only frontend shows errors** (it's the one making DNS lookups)
- Backend services show NO errors (they never receive requests)
- **This pattern indicates DNS issue**, not backend service problems

---

## Honeycomb Dashboard Configuration

Create a board named **"DNS Resolution Failure Analysis"** with these panels:

### Panel 1: Frontend Error Rate
```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY otel.status_code
```

### Panel 2: DNS Error Messages
```
WHERE service.name = frontend AND error = true
VISUALIZE COUNT
GROUP BY error.message
```

### Panel 3: Request Latency Heatmap
```
WHERE service.name = frontend
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
```

### Panel 4: Service Call Success Rate
```
WHERE service.name = frontend AND span.kind = CLIENT
VISUALIZE COUNT
GROUP BY name, otel.status_code
```

### Panel 5: Trace Completeness
```
WHERE trace.parent_id = null AND service.name = frontend
VISUALIZE COUNT
GROUP BY has_children
```

### Panel 6: Error Distribution Across Services
```
WHERE otel.status_code = ERROR
VISUALIZE COUNT
GROUP BY service.name
```

### Panel 7: Frontend Request Rate
```
WHERE service.name = frontend
VISUALIZE COUNT
GROUP BY time(30s)
```

### Panel 8: P95 Latency Trend
```
WHERE service.name = frontend
VISUALIZE P95(duration_ms)
GROUP BY time(30s)
```

---

## Expected Timeline

| Time | Action | DNS Status | Frontend Behavior | Traces Observable |
|------|--------|------------|------------------|-------------------|
| 0s | Baseline | ✅ Working | All requests succeed | Complete traces with backend spans |
| +10s | Scale CoreDNS to 0 | ❌ Stopping | DNS lookups may succeed from cache | Mix of success/failure (varies by service) |
| +30s-60s | DNS cache expires | ❌ Down | DNS lookups start failing | Traces show "no such host" errors |
| +60s+ | Users see errors | ❌ Down | Failure rate increases | Traces have no child spans |
| +120s | Continue monitoring | ❌ Down | Sustained failures | Clear pattern: all DNS errors |
| +300s | Restore CoreDNS | ⚠️ Starting | Some requests start succeeding | Mix of success/failure |
| +320s | DNS fully restored | ✅ Working | All requests succeed | Complete traces return |

**DNS Cache Note:** DNS cache behavior is **highly variable** and depends on:
- **Application runtime**: Go services may cache indefinitely, Node.js varies by library, Java depends on JVM settings
- **CoreDNS TTL**: Often 30 seconds by default, but configurable
- **Connection pooling**: Existing connections bypass DNS
- **Result**: Failures may appear **immediately** for some services, or take **several minutes** for others (especially Go services)

---

## Trace Analysis - Isolating DNS as Root Cause

**Important:** The error messages shown in these examples are illustrative. Actual error messages will vary depending on:
- Programming language (Go, Node.js, Python, Java, C#, Ruby, etc.)
- HTTP client library (native, axios, requests, OkHttp, etc.)
- OpenTelemetry instrumentation implementation

**Focus on these patterns instead of exact text:**
- Error message contains keywords: **"lookup"**, **"no such host"**, **"name resolution"**, **"dial"**
- **No child spans** in the trace (connection never established)
- Duration matches DNS timeout (~5 seconds)
- Error has **no IP address** (vs. service down which shows resolved IP)

### Example: Healthy Trace (Before DNS Failure)

**Trace Structure:**
```
frontend [200ms total]
  └─ GET /cart [150ms]
      ├─ DNS lookup: cart → 10.0.1.15 [2ms]
      ├─ TCP connect: 10.0.1.15:8080 [5ms]
      ├─ HTTP request [140ms]
      │   └─ cart service processing [130ms]
      └─ HTTP response [3ms]
```

**Indicators:**
- ✅ DNS lookup succeeds quickly (2ms)
- ✅ TCP connection established
- ✅ Backend service span present
- ✅ Response received

### Example: DNS Failure Trace (After DNS Stopped)

**Trace Structure:**
```
frontend [5023ms total] ❌ ERROR
  └─ GET /cart [5023ms] ❌ ERROR
      ├─ DNS lookup: cart [5000ms] ❌ TIMEOUT
      └─ Error: "dial tcp: lookup cart: no such host"
```

**Indicators:**
- ❌ DNS lookup takes 5000ms (timeout)
- ❌ No TCP connection span (never attempted)
- ❌ **No backend service span** (critical indicator)
- ❌ Error message specifically mentions DNS/lookup
- ❌ Total duration = DNS timeout (not variable)

### Example: Service Down Trace (For Comparison)

**Trace Structure:**
```
frontend [25ms total] ❌ ERROR
  └─ GET /cart [25ms] ❌ ERROR
      ├─ DNS lookup: cart → 10.0.1.15 [2ms] ✅
      ├─ TCP connect: 10.0.1.15:8080 [3ms] ❌ REFUSED
      └─ Error: "dial tcp 10.0.1.15:8080: connect: connection refused"
```

**Indicators:**
- ✅ DNS lookup succeeds (2ms)
- ❌ TCP connection refused
- Error message mentions IP address (DNS worked)
- **This is NOT a DNS issue** - this is service down

### How to Distinguish in Honeycomb Traces

**View Traces in Honeycomb UI:**
```
Open: https://ui.honeycomb.io
Navigate to: Frontend service traces

Query:
WHERE service.name = frontend AND otel.status_code = ERROR
VISUALIZE TRACES
```

**Click on a trace and look for these patterns:**

| Indicator | DNS Failure | Service Down | Database Error |
|-----------|-------------|--------------|----------------|
| **Error Message Keywords** | `no such host`, `lookup`, `name resolution` | `connection refused`, IP in error | `database`, `SQLSTATE` |
| **Child Spans** | None (never reached backend) | None (connection failed) | Yes (connection succeeded) |
| **Duration** | ~5000ms (DNS timeout) | <100ms (fast failure) | Variable (query timeout) |
| **IP Address in Error** | No (DNS never resolved) | Yes (shows resolved IP) | Yes (connected successfully) |

**Note:** Error message exact wording varies by language/library, but the **pattern** is consistent.

**Quick Diagnostic Rule:**
- Error contains keywords **"lookup"** OR **"no such host"** → DNS problem ✅
- Error contains **IP address** → DNS worked, service/network problem ❌
- Backend spans **present** but fail → Application/database problem ❌

---

## Cleanup / Restore DNS

### Restore CoreDNS

```bash
# Restore CoreDNS to original replica count (usually 2)
kubectl scale deployment coredns -n kube-system --replicas=2

# Verify CoreDNS is running
kubectl get pod -n kube-system -l k8s-app=kube-dns

# Expected output:
# NAME                       READY   STATUS    RESTARTS   AGE
# coredns-565d847f94-abc12   1/1     Running   0          5s
# coredns-565d847f94-def34   1/1     Running   0          5s
```

### Verify DNS Resolution Works

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
- Check frontend traces - should show successful requests with child spans
- Access demo UI (`http://localhost:8080`) and verify browsing works

### Stop Load Test

1. Go to Locust UI: http://localhost:8089
2. Click **"Stop"** button

---

## Troubleshooting

### CoreDNS Not in kube-system Namespace

**Find CoreDNS:**
```bash
kubectl get deployment --all-namespaces | grep -i dns
```

**Common locations:**
- `kube-system` namespace (most common)
- `openshift-dns` namespace (OpenShift)
- Custom namespace in managed Kubernetes

### CoreDNS Replica Count Unknown

**Check current replicas before scaling:**
```bash
kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.replicas}'

# Save this number to restore later
```

### DNS Failures Not Appearing

**Check if DNS is actually stopped:**
```bash
kubectl get pod -n kube-system -l k8s-app=kube-dns
# Should show: No resources found
```

**Check DNS from pod:**
```bash
kubectl exec -n otel-demo deployment/frontend -- nslookup cart
# Should show DNS timeout/failure
```

**Force DNS cache expiry (for Go services especially):**
```bash
# Restart frontend pods to clear DNS cache (Go caches indefinitely)
kubectl rollout restart deployment/frontend -n otel-demo
kubectl rollout restart deployment/checkout -n otel-demo
kubectl rollout restart deployment/cart -n otel-demo
```

**Alternative: Pre-populate cache then test (recommended for consistent results):**
```bash
# 1. Scale CoreDNS UP to ensure good DNS resolution
kubectl scale deployment coredns -n kube-system --replicas=10

# 2. Generate traffic to populate DNS cache across all services
# (use Locust or browse the demo for 1-2 minutes)

# 3. Scale CoreDNS DOWN to 0 to break DNS
kubectl scale deployment coredns -n kube-system --replicas=0

# 4. Observe gradual failures as cache expires per service
# Go services may take 5+ minutes, others may fail immediately
```

This approach shows more realistic cache behavior - some services fail immediately, others continue on cached entries.

### Services Still Working After Stopping DNS

**Possible causes:**

1. **DNS Cache:** Pods cache DNS results, but timing varies widely:
   - **Go services** (frontend, checkout, cart): May cache **indefinitely** until process restart
   - **Other runtimes**: Varies from immediate to several minutes
   - **Recommendation**: Wait 2-5 minutes OR restart pods to clear cache

2. **IP-based communication:** Some services may use IP addresses directly instead of DNS names.

3. **Local /etc/hosts:** Some pods may have static entries in `/etc/hosts`.

**Check DNS configuration in pod:**
```bash
kubectl exec -n otel-demo deployment/frontend -- cat /etc/resolv.conf

# Should show:
# nameserver 10.96.0.10  (CoreDNS IP)
# search otel-demo.svc.cluster.local svc.cluster.local cluster.local
```

### Cannot Scale CoreDNS (Permissions)

**Check permissions:**
```bash
kubectl auth can-i update deployment -n kube-system

# If no, you need cluster-admin or proper RBAC
```

**Alternative (if you have namespace permissions):**

Instead of stopping CoreDNS, add a bad DNS entry to service:
```bash
# This is more complex and not recommended for this scenario
```

### Cluster Becomes Unstable After Stopping CoreDNS

**⚠️ This is expected!** DNS is critical infrastructure.

**Immediately restore CoreDNS:**
```bash
kubectl scale deployment coredns -n kube-system --replicas=2
```

**Best practice:** Only do this in:
- Dedicated demo/test clusters
- Clusters you can rebuild
- Clusters not running other workloads

---

## Alert Configuration

### Alert 1: High Frontend Error Rate

```
TRIGGER: COUNT WHERE otel.status_code = ERROR > 10
WHERE: service.name = frontend
FREQUENCY: Every 1 minute
ACTION: Warning - frontend experiencing high error rate
```

### Alert 2: DNS Lookup Failures

```
TRIGGER: COUNT WHERE error.message CONTAINS "no such host" > 5
WHERE: service.name = frontend
FREQUENCY: Every 30 seconds
ACTION: Critical - DNS resolution failures detected
```

### Alert 3: Service Call Success Rate Drop

```
TRIGGER: (COUNT WHERE otel.status_code = OK) / (COUNT) < 0.5
WHERE: service.name = frontend AND span.kind = CLIENT
FREQUENCY: Every 1 minute
ACTION: Critical - service-to-service communication failing
```

### Alert 4: Increased Request Latency

```
TRIGGER: P95(duration_ms) > 4000
WHERE: service.name = frontend
FREQUENCY: Every 1 minute
ACTION: Warning - DNS timeout pattern detected (5s timeout)
```

---

## Learning Outcomes

After completing this use case, you will have observed:

1. ✅ **DNS resolution failures** and their impact on service mesh
2. ✅ **Cascading failures** when infrastructure service fails
3. ✅ **Trace patterns** that distinguish DNS issues from application issues
4. ✅ **Error message pattern analysis** for root cause identification (not exact text matching)
5. ✅ **Service dependency mapping** through failure propagation
6. ✅ **DNS timeout behavior** in containerized environments
7. ✅ **Isolation techniques** to prove DNS as root cause using Honeycomb trace waterfall
8. ✅ **Recovery patterns** when infrastructure is restored
9. ✅ **Language-agnostic diagnostic patterns** that work across all services regardless of runtime

---

## Production Scenarios Simulated

This demo replicates these real-world issues:

1. **CoreDNS Pod Failures** - DNS pods crash or get evicted
2. **DNS Service Disruption** - Network policy blocks DNS traffic
3. **DNS Cache Poisoning** - Incorrect DNS responses
4. **Split-Brain DNS** - Partial DNS availability
5. **DNS Query Overload** - DNS service overwhelmed
6. **Kubernetes Control Plane Issues** - DNS updates not propagating

---

## Key Takeaways

### For Diagnosing DNS Issues

**DNS Problem Indicators:**
- ✅ Error messages contain "lookup", "no such host", "name resolution"
- ✅ Errors affect **all backend services uniformly**
- ✅ Request duration = DNS timeout (~5 seconds)
- ✅ **No child spans** in traces (never reached backends)
- ✅ Error message has **no IP address** (DNS never resolved)

**NOT DNS Problem:**
- ❌ Error shows IP address (DNS worked, connection failed)
- ❌ Backend spans present but errored (DNS worked, app failed)
- ❌ Only specific service fails (not all services)
- ❌ Variable latency (not consistent timeout)

### For SREs/Platform Engineers

- **DNS is single point of failure** in Kubernetes
- **Monitor CoreDNS health** separately from applications
- **DNS failures cascade** to all services immediately
- **Traces clearly show** DNS vs application vs database issues
- **Alert on DNS-specific error patterns** for faster detection

### For Observability

- **Trace structure** is more important than metrics for root cause
- **Error message content** distinguishes between failure types
- **Absence of child spans** indicates connection never established
- **Consistent timeout duration** indicates infrastructure issue
- **Honeycomb trace waterfall** makes DNS failures obvious

---

## Comparison: DNS vs Other Infrastructure Failures

| Failure Type | Affected Services | Error Location | Child Spans | Duration Pattern |
|--------------|-------------------|----------------|-------------|------------------|
| **DNS Down** | All services | Client side (lookup) | None | Consistent (5s timeout) |
| **Service Down** | One service | Client side (connect) | None | Fast (<100ms) |
| **Network Partition** | Subset of services | Client side (TCP) | None | Variable (TCP timeout) |
| **Database Down** | Services using DB | Server side (query) | Present | Variable (query timeout) |
| **Application Error** | One service | Server side (logic) | Present | Variable (processing time) |

---

## Next Steps

### Extend the Use Case

1. **Partial DNS Failure / Insufficient Capacity (Recommended Variation):**

   This variation demonstrates **DNS capacity issues** rather than total failure, showing how cache behavior varies across services:

   ```bash
   # Step 1: Scale CoreDNS UP to ensure DNS works well
   kubectl scale deployment coredns -n kube-system --replicas=10

   # Step 2: Generate sustained traffic to populate DNS cache across all services
   # Use Locust with 50 users for 2-3 minutes to ensure all services have cached DNS entries

   # Step 3: Scale CoreDNS DOWN to insufficient capacity (1-2 replicas)
   kubectl scale deployment coredns -n kube-system --replicas=1

   # Step 4: Observe gradual degradation as cache expires per service:
   # - Services with expired cache start experiencing DNS lookup delays
   # - Go services (frontend, checkout, cart) continue working on cached entries
   # - Other services may fail immediately or have slow DNS lookups
   # - CoreDNS becomes overloaded with queries from cache misses

   # Step 5: Monitor in Honeycomb for mixed success/failure patterns
   # - Some requests succeed (cached DNS)
   # - Some requests slow (DNS lookup queued)
   # - Some requests fail (DNS timeout)
   ```

   **Observable Patterns:**
   - **Mixed errors**: Some succeed, some timeout
   - **Gradual degradation**: Services fail at different times as cache expires
   - **CoreDNS CPU saturation**: High CPU on remaining CoreDNS pod
   - **Variable latency**: Requests waiting for DNS resolution

   This is more realistic than total DNS failure and demonstrates capacity planning issues.

2. **DNS Latency:**
   - Use network policies to add latency to DNS queries
   - Observe slow but successful DNS resolution

3. **DNS Cache Tuning:**
   - Modify pod DNS TTL settings
   - Observe different cache expiration behaviors

4. **Service Mesh Integration:**
   - Test with Istio/Linkerd sidecar proxies
   - Observe how service mesh handles DNS failures

5. **Create SLO for DNS availability:**
   - Define acceptable DNS resolution time (e.g., P95 < 50ms)
   - Track error budget burn during DNS outages

---

## References

- [Kubernetes DNS Specification](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [CoreDNS Documentation](https://coredns.io/manual/toc/)
- [OpenTelemetry Semantic Conventions - HTTP](https://opentelemetry.io/docs/specs/semconv/http/)
- [Debugging DNS Resolution in Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)

---

## Summary

This use case demonstrates **DNS resolution failure** using:

- ✅ Zero code changes required
- ✅ Kubernetes infrastructure manipulation (CoreDNS scaling)
- ✅ Observable in Honeycomb traces with clear DNS error patterns
- ✅ Trace analysis showing **no child spans** (never reached backends)
- ✅ Error messages containing DNS-specific keywords
- ✅ Isolation technique: DNS errors vs application vs database
- ✅ Dashboard configuration for DNS monitoring
- ✅ Alert configuration for DNS-specific patterns
- ✅ Production-realistic DNS failure scenarios

**Key difference from other scenarios:** This demonstrates **infrastructure failure** affecting all services uniformly, with traces clearly showing DNS as the root cause through error messages and absence of child spans - not application bugs or database issues.

**Critical Diagnostic Rule:** If traces show errors with keywords like **"no such host"**, **"lookup"**, or **"name resolution"** AND **no backend spans**, it's DNS. If traces show an **IP address** in the error or have **child spans**, it's not DNS.

**Note on Error Messages:** The exact error message text varies by programming language and HTTP client library. Always look for the **pattern and keywords** described in this guide rather than exact string matches. The key is the presence of DNS-related keywords and the absence of child spans in the trace waterfall view in Honeycomb.
