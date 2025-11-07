# Frontend Flood Homepage - Service Overload Chaos Test

**Test Type:** Resource Exhaustion / Service Overload  
**Target Service:** Frontend (Python/Flask)  
**Trigger:** Feature flag `loadGeneratorFloodHomepage`  
**Duration:** Configurable (recommend 5-10 minutes)  
**Difficulty:** ⭐ Easy

---

## 🎯 **What This Test Does**

Floods the frontend service with a massive volume of homepage requests, causing:

- CPU and memory exhaustion
- Connection pool saturation
- Increased latency and timeouts
- Potential service degradation or crashes

### Important: Envoy Architecture

**All requests flow through Envoy (frontend-proxy), but rate limiting is NOT configured.**

```
Load Generator (Locust)
    ↓ HTTP to http://frontend-proxy:8080
Frontend-Proxy (Envoy) ← All traffic routes through here
    ↓ No rate limiting configured → passes all requests
Frontend Service (Python/Flask)
    ↓ Gets overwhelmed → 500/503 errors
```

**This test demonstrates:**
- ✅ **Service overload** - Frontend exhaustion with 500/503 errors
- ❌ **NOT rate limiting** - Envoy would return 429 errors if rate limits were configured

**To enable rate limiting**, you would need to add `envoy.filters.http.local_ratelimit` to `src/frontend-proxy/envoy.tmpl.yaml`.

---

## 📋 **Prerequisites**

- OpenTelemetry Demo running
- Load generator active (Locust)
- Access to FlagD UI (http://localhost:4000)
- Honeycomb or similar observability platform

---

## ⚙️ **Test Configuration**

### Feature Flag Settings

**Flag:** `loadGeneratorFloodHomepage`

**Variants:**

- `on: 100` - Each user makes 100 sequential homepage requests per cycle
- `off: 0` - Normal behavior (no flooding)

**Recommended Settings:**

| Users | Flood Count | Total Requests/Cycle | Impact Level |
| ----- | ----------- | -------------------- | ------------ |
| 10    | 100         | 1,000                | ⚠️ Light     |
| 25    | 100         | 2,500                | 🟡 Moderate  |
| 50    | 100         | 5,000                | 🟠 Heavy     |
| 100   | 100         | 10,000               | 🔴 Severe    |

---

## 📝 **Step-by-Step Execution**

### Step 1: Check Baseline Frontend Status

```bash
# Check frontend pod status
kubectl get pods -n otel-demo -l app.kubernetes.io/component=frontend

# Check current resource usage
kubectl top pod -n otel-demo -l app.kubernetes.io/component=frontend

# Check current request rate (if available)
kubectl logs -n otel-demo -l app.kubernetes.io/component=frontend --tail=50
```

**Expected Baseline:**

```
CPU: 20-50m (low)
Memory: 80-120Mi
Status: 2/2 Running
Errors: Minimal or none
```

---

### Step 2: Configure Load Generator

1. **Access Locust UI:**

   ```
   http://localhost:8089
   ```

2. **Set User Count:**

   - For first test: **25 users** (moderate impact)
   - Spawn rate: **5** users per second
   - Runtime: **10 minutes** (600 seconds)

3. **Start Load Generator** (but don't enable flag yet)

---

### Step 3: Enable Feature Flag

1. **Access FlagD UI:**

   ```
   http://localhost:4000
   ```

2. **Find `loadGeneratorFloodHomepage` flag**

3. **Configure:**

   - Set **defaultVariant** to `on`
   - Confirm `on` variant value is `100`
   - Save changes

4. **Verify flag is active:**
   ```bash
   kubectl logs -n otel-demo -l app.kubernetes.io/component=flagd --tail=20
   ```

---

### Step 4: Monitor Frontend Impact

#### Real-Time CPU/Memory Monitoring

```bash
# Watch frontend resources (updates every 5 seconds)
watch -n 5 'kubectl top pod -n otel-demo -l app.kubernetes.io/component=frontend'
```

**Expected Progression:**

```
Time    CPU      Memory    Status
0m      30m      100Mi     Normal
1m      150m     180Mi     Load increasing
2m      350m     250Mi     Heavy load
3m      500m+    300Mi+    Overload
```

#### Watch Frontend Logs for Errors

```bash
# Stream frontend logs
kubectl logs -n otel-demo -l app.kubernetes.io/component=frontend -f | grep -i "error\|timeout\|failed"
```

**Expected Errors:**

```
Error: Request timeout
Error: Connection pool exhausted
Error: Too many requests
OSError: [Errno 24] Too many open files
```

#### Check Active Connections

```bash
# Check number of frontend pods and their connections
kubectl exec -n otel-demo <frontend-pod> -c frontend -- \
  sh -c 'netstat -an | grep ESTABLISHED | wc -l'
```

---

### Step 5: Observe Blast Radius

#### Check Dependent Services

**Product-Catalog (called by frontend):**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/component=product-catalog --tail=50
```

**Expected:**

- Increased request volume
- Possible timeout errors from frontend
- Higher latency

**Checkout Service:**

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/component=checkout --tail=50
```

**Expected:**

- Increased traffic during flood
- Potential connection issues

---

### Step 6: Stop Test and Verify Recovery

#### Disable Feature Flag

1. Go to FlagD UI: http://localhost:4000
2. Set `loadGeneratorFloodHomepage` defaultVariant to `off`
3. Save changes

#### Verify Recovery

```bash
# Check frontend returns to normal
kubectl top pod -n otel-demo -l app.kubernetes.io/component=frontend

# Verify no more errors
kubectl logs -n otel-demo -l app.kubernetes.io/component=frontend --tail=20 --since=1m

# Check pod is healthy
kubectl get pods -n otel-demo -l app.kubernetes.io/component=frontend
```

**Expected Recovery:**

```
CPU: Returns to 20-50m within 30 seconds
Memory: Slowly decreases to baseline
Errors: Stop appearing
Status: 2/2 Running (no restarts needed)
```

---

## 📊 **Expected Results**

### Frontend Service Impact

| Metric                    | Before | During Flood | Impact           |
| ------------------------- | ------ | ------------ | ---------------- |
| **CPU Usage**             | 20-50m | 400-800m     | 8-16x increase   |
| **Memory Usage**          | 100Mi  | 250-400Mi    | 2.5-4x increase  |
| **Request Latency (P95)** | 50ms   | 500-2000ms   | 10-40x increase  |
| **Error Rate**            | <0.1%  | 5-20%        | 50-200x increase |
| **Active Connections**    | 10-20  | 100-300      | 5-15x increase   |

### Error Types Observed

1. **Connection Errors:**

   ```
   ConnectionError: HTTPConnectionPool(host='frontend', port=8080): Max retries exceeded
   ```

2. **Timeout Errors:**

   ```
   TimeoutError: Request to / timed out after 30 seconds
   ```

3. **Resource Exhaustion:**

   ```
   OSError: [Errno 24] Too many open files
   MemoryError: Unable to allocate array
   ```

4. **HTTP Status Codes:**
   - 500 Internal Server Error (service overwhelmed)
   - 503 Service Unavailable (can't handle requests)
   - 504 Gateway Timeout (response too slow)

---

## 🔍 **Blast Radius Analysis**

### Service Dependency Chain

```
Load Generator (Locust)
    ↓ 100 requests per user per cycle
    ↓ Target: http://frontend-proxy:8080/
Frontend-Proxy (Envoy)
    ↓ No rate limiting → all requests pass through
    ↓ Routes to backend services
Frontend (Python/Flask)
    ↓ Resource exhaustion: CPU/memory overwhelmed
    ↓ Calls product-catalog, checkout, cart, etc.
Product-Catalog (Go)
    ↓ Increased query volume
PostgreSQL
    ↓ More database queries
Potential cascade failures
```

### What Would Happen WITH Rate Limiting

If Envoy rate limiting was configured (e.g., 100 requests/minute):

```
Load Generator (Locust)
    ↓ 10,000 requests/minute
Frontend-Proxy (Envoy)
    ✋ Rate limit enforced
    ↓ Accepts: 100 requests (pass to frontend)
    ↓ Rejects: 9,900 requests (429 Too Many Requests)
Frontend (Python/Flask)
    ↓ Only receives 100 requests
    ✅ Handles load normally → 200 OK
    ↓ No resource exhaustion
```

**Key Difference:**
- **Without rate limiting (current):** Frontend gets overwhelmed → 500/503 errors
- **With rate limiting (not configured):** Envoy protects frontend → 429 errors

### Impact by Service

**Frontend (Primary Target):**

- 🔴 **Direct Impact** - Resource exhaustion
- CPU saturation (400-800m)
- Memory pressure (250-400Mi)
- Connection pool exhaustion
- High error rate (5-20%)

**Product-Catalog (Secondary):**

- 🟡 **Indirect Impact** - Increased call volume
- Higher query rate
- Potential timeout errors
- Database connection pressure

**Cart/Checkout Services (Tertiary):**

- 🟢 **Minor Impact** - Increased traffic
- Mostly handles increased volume fine
- Potential timeout on slow responses

**Database (Quaternary):**

- 🟢 **Minimal Impact** - Query volume increase
- No direct stress
- May see increased connections

---

## 📈 **Honeycomb Queries**

### Frontend Request Rate

```
WHERE: service.name = "frontend" AND name = "GET /"
VISUALIZE: COUNT
GROUP BY: time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:** Spike from 50-100 req/min to 5,000-10,000 req/min

### Frontend Error Rate

```
WHERE: service.name = "frontend" AND error EXISTS
VISUALIZE: COUNT, COUNT / COUNT(service.name = "frontend") * 100 AS "Error %"
BREAKDOWN: error
GROUP BY: time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:** Error rate increases from <0.1% to 5-20%

### Frontend Latency

```
WHERE: service.name = "frontend" AND name = "GET /"
VISUALIZE: P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY: time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:**

- P50: 20ms → 200ms (10x)
- P95: 50ms → 1000ms (20x)
- P99: 100ms → 3000ms+ (30x+)

### Frontend HTTP Status Codes

```
WHERE: service.name = "frontend"
VISUALIZE: COUNT
BREAKDOWN: http.status_code
GROUP BY: time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:** Increase in 500, 503, 504 status codes

---

## 🎯 **Key Differences from Other Tests**

| Test                      | Target              | Method              | Error Type           | Envoy Involved? |
| ------------------------- | ------------------- | ------------------- | -------------------- | --------------- |
| **Frontend Flood**        | Frontend service    | High request volume | 500/503/timeout      | ✅ Yes (passes all requests) |
| **Connection Exhaustion** | PostgreSQL          | Hold connections    | "too many clients"   | ❌ No (internal DB) |
| **IOPS Pressure**         | PostgreSQL          | Heavy I/O           | EOF, "shutting down" | ❌ No (internal DB) |
| **Kafka Queue**           | Checkout/Accounting | Message flood       | Kafka lag, OOM       | ❌ No (internal messaging) |

**Unique Aspects:**
- This is the only test that routes through **Envoy (frontend-proxy)**
- Demonstrates service overload when rate limiting is NOT configured
- Could be modified to demonstrate rate limit enforcement by configuring Envoy

---

## ⚠️ **Important Notes**

### Frontend Service Limits

**Memory Limit:**

```yaml
resources:
  limits:
    memory: 1000Mi # Frontend can handle up to 1GB
```

**Risk Levels:**

- **25 users × 100 requests** = ⚠️ Safe (will not OOM)
- **50 users × 100 requests** = 🟡 Moderate (high load, no OOM)
- **100 users × 100 requests** = 🔴 Risky (may approach memory limit)

### Recovery Time

- **CPU:** Returns to baseline in 30-60 seconds
- **Memory:** Gradually decreases over 2-5 minutes
- **Connections:** Close within 1-2 minutes
- **No restart needed** in most cases

### When to Stop Early

Stop the test immediately if:

- ❌ Frontend pod shows `OOMKilled` status
- ❌ Frontend becomes completely unresponsive (no logs for 60+ seconds)
- ❌ Other services start cascading failures
- ❌ Kubernetes evicts the frontend pod

---

## 🔧 **Troubleshooting**

### Frontend Not Showing Load

**Check:**

1. Is the load generator running? (http://localhost:8089)
2. Is the flag actually enabled? (http://localhost:4000)
3. Are users actually spawned in Locust?

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/component=load-generator --tail=50
```

### Frontend OOM Killed

**Recovery:**

```bash
# Frontend will auto-restart, but you can force it
kubectl rollout restart deployment frontend -n otel-demo

# Verify recovery
kubectl get pods -n otel-demo -l app.kubernetes.io/component=frontend
```

### Test Impact Too Severe

**Reduce load:**

1. Stop Locust (http://localhost:8089 → Stop)
2. Disable flag (http://localhost:4000 → `loadGeneratorFloodHomepage` → off)
3. Reduce users: 100 → 50 → 25
4. Restart with lower settings

---

## 🎓 **Learning Outcomes**

After completing this test, you will have observed:

1. ✅ **Service overload patterns** - How services behave under extreme load
2. ✅ **Resource exhaustion** - CPU, memory, connection limits
3. ✅ **Error propagation** - How frontend errors affect dependent services
4. ✅ **Recovery behavior** - How services self-heal after load reduction
5. ✅ **Observability effectiveness** - Can you detect and diagnose the issue?
6. ✅ **Resource limits** - Understanding service capacity limits
7. ✅ **Envoy request flow** - All HTTP traffic routes through frontend-proxy
8. ✅ **Rate limiting gaps** - Understanding when rate limits would help vs. service scaling

### Optional: Adding Rate Limiting

To extend this test and demonstrate Envoy rate limiting, add to `src/frontend-proxy/envoy.tmpl.yaml`:

```yaml
http_filters:
  - name: envoy.filters.http.local_ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
      stat_prefix: http_local_rate_limiter
      token_bucket:
        max_tokens: 100
        tokens_per_fill: 100
        fill_interval: 60s  # 100 requests per minute
      filter_enabled:
        runtime_key: local_rate_limit_enabled
        default_value:
          numerator: 100
          denominator: HUNDRED
      filter_enforced:
        runtime_key: local_rate_limit_enforced
        default_value:
          numerator: 100
          denominator: HUNDRED
      response_headers_to_add:
        - append: false
          header:
            key: x-local-rate-limit
            value: 'true'
  - name: envoy.filters.http.fault
    # existing fault filter...
  - name: envoy.filters.http.router
    # existing router...
```

**With rate limiting configured:**
- Requests exceeding 100/min would get **429 Too Many Requests**
- Frontend service would be **protected** from overload
- Error type changes from **500/503** (service overload) to **429** (rate limited)

---

## 📚 **Related Tests**

- **Connection Exhaustion:** `infra/postgres-chaos/docs/CONNECTION-EXHAUSTION-TEST-RESULTS.md`
- **IOPS Pressure:** `infra/postgres-chaos/docs/IOPS-BLAST-RADIUS-TEST-RESULTS.md`
- **Kafka Queue Problems:** Feature flag `kafkaQueueProblems`
- **Memory Leak (Email):** Feature flag `emailMemoryLeak`

---

## ✅ **Success Criteria**

The test is successful when you can demonstrate:

1. ✅ **Load increase visible** - Frontend CPU/memory spike observable
2. ✅ **Errors generated** - 500/503/timeout errors appearing
3. ✅ **Latency degradation** - P95/P99 latency increases significantly
4. ✅ **Monitoring works** - Honeycomb shows the impact clearly
5. ✅ **Recovery verified** - Service returns to normal after flag disabled
6. ✅ **No permanent damage** - No data loss, no restart needed

---

**Test Type:** Frontend Service Overload  
**Difficulty:** ⭐ Easy  
**Duration:** 5-10 minutes  
**Status:** ✅ Safe for demo environments  
**Recovery:** Automatic, no intervention needed
