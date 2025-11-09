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

**All requests flow through Envoy (frontend-proxy), with rate limiting NOW CONFIGURED (500 req/min).**

```
Load Generator (Locust)
    ↓ HTTP to http://frontend-proxy:8080
Frontend-Proxy (Envoy) ← All traffic routes through here
    ↓ Rate limit: 500 req/min → returns 429 if exceeded
Frontend Service (Python/Flask)
    ↓ Protected by rate limit → max 500 req/min
```

**This test can demonstrate:**

- ✅ **Rate limiting (429 errors)** - Envoy protects frontend by rejecting excess requests
- ✅ **Service overload** - Frontend exhaustion if rate limit is high enough (500/503 errors)

**Rate limit is configured** in `src/frontend-proxy/envoy.tmpl.yaml` with `envoy.filters.http.local_ratelimit` at 500 req/min.

📋 **See:** `chaos-scenarios/envoy-rate-limit-alert.md` for rate limit monitoring and alerting.

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

- `off: 0` - Normal behavior (no flooding)
- `light: 10` - Light load increase (realistic spike)
- `moderate: 25` - Moderate service stress (good for demos)
- `heavy: 50` - Heavy application-level overload
- `extreme: 100` - Extreme (overwhelms Envoy connection management)

**⚠️ Important:** Start with `light` or `moderate`. The `extreme` setting overwhelms Envoy's connection layer before traffic reaches the frontend service, which isn't realistic for most scenarios.

**Recommended Test Scenarios:**

| Variant    | Users | Requests/User | Total Req/Cycle | Impact                   | Target           |
| ---------- | ----- | ------------- | --------------- | ------------------------ | ---------------- |
| `light`    | 25    | 10            | 250             | ⚠️ Light                 | Frontend service |
| `moderate` | 25    | 25            | 625             | 🟡 Moderate              | Frontend service |
| `moderate` | 50    | 25            | 1,250           | 🟠 Heavy                 | Frontend service |
| `heavy`    | 50    | 50            | 2,500           | 🔴 Severe                | Frontend service |
| `extreme`  | 25    | 100           | 2,500           | 💥 Connection exhaustion | **Envoy proxy**  |
| `extreme`  | 50    | 100           | 5,000           | 💥 Complete overload     | **Envoy proxy**  |

**Best for Learning:** Start with `moderate` at 25 users - shows clear service degradation without overwhelming connection management.

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

   - For first test: **25 users**
   - Spawn rate: **5** users per second
   - Runtime: **10 minutes** (600 seconds)

3. **Start Load Generator** (but don't enable flag yet - this establishes baseline)

---

### Step 3: Enable Feature Flag

1. **Access FlagD UI:**

   ```
   http://localhost:4000
   ```

2. **Find `loadGeneratorFloodHomepage` flag**

3. **Configure:**

   - **Recommended for first test:** Set **defaultVariant** to `moderate` (25 requests/user)
   - **Alternative:** Use `light` (10 requests/user) for gentler introduction
   - **Advanced:** Use `heavy` (50) or `extreme` (100) for more severe tests
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

**With Realistic Settings (light/moderate/heavy):**

```
Load Generator (Locust)
    ↓ 10-50 requests per user per cycle
    ↓ Target: http://frontend-proxy:8080/
Frontend-Proxy (Envoy)
    ↓ Handles connection management
    ↓ Routes to backend services
    ✅ Passes traffic through successfully
Frontend (Python/Flask)
    ↓ Resource exhaustion: CPU/memory overwhelmed
    ↓ Application-level overload → 500/503 errors
    ↓ Calls product-catalog, checkout, cart, etc.
Product-Catalog (Go)
    ↓ Increased query volume
PostgreSQL
    ↓ More database queries
Potential cascade failures
```

**⚠️ With Extreme Setting (100 requests/user):**

```
Load Generator (Locust)
    ↓ 100 requests per user per cycle
    ↓ Opens thousands of concurrent connections
Frontend-Proxy (Envoy)
    ✋ Connection management overwhelmed
    ↓ Cannot handle connection volume
    ↓ Errors at proxy layer → 500/503/504
    ↓ Many requests never reach frontend
Frontend (Python/Flask)
    ↓ Only receives partial traffic
    ✅ May appear healthy (not getting overwhelmed)
```

**Key Difference:**

- **Realistic settings:** Demonstrate application-level service overload
- **Extreme setting:** Demonstrate infrastructure-level (proxy) exhaustion

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

## 📈 **Honeycomb Queries for Blast Radius Analysis**

### 🎯 PRIMARY IMPACT: Frontend Service

#### 1. Frontend Request Volume Spike

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:**

- **Baseline:** 50-100 requests/min
- **During Flood:** 5,000-10,000 requests/min
- **Spike:** 50-100x increase

**What to look for:**

- Sharp vertical spike when flag enabled
- Sustained high volume while test runs
- Rapid drop when flag disabled

---

#### 2. Frontend Error Rate (Service Overload)

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
  AND http.status_code >= 500
VISUALIZE COUNT
BREAKDOWN http.status_code
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected Status Codes:**

- `500` Internal Server Error (service overwhelmed)
- `503` Service Unavailable (connection pool exhausted)
- `504` Gateway Timeout (response too slow)

**Baseline vs Flood:**

- Baseline: <1 error per minute (<0.1%)
- Flood: 50-200 errors per minute (5-20%)

---

#### 3. Frontend Latency Degradation

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE P50(duration_ms) AS "P50 (median)",
         P95(duration_ms) AS "P95 (95th percentile)",
         P99(duration_ms) AS "P99 (99th percentile)",
         MAX(duration_ms) AS "Max"
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected Degradation:**

| Metric | Baseline | During Flood  | Multiplier |
| ------ | -------- | ------------- | ---------- |
| P50    | 20ms     | 200-500ms     | 10-25x     |
| P95    | 50ms     | 1,000-2,000ms | 20-40x     |
| P99    | 100ms    | 3,000-5,000ms | 30-50x     |
| Max    | 200ms    | 10,000ms+     | 50-100x    |

---

#### 4. Frontend Error Types Breakdown

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
  AND error = true
VISUALIZE COUNT
BREAKDOWN exception.type, exception.message
TIME RANGE: Last 15 minutes
```

**Expected Errors:**

- `TimeoutError`: Request timeout after 30s
- `ConnectionError`: Connection pool exhausted
- `OSError`: Too many open files
- `MemoryError`: Memory allocation failed

---

### 🔍 BLAST RADIUS: Downstream Services

#### 5. Product-Catalog Impact (Secondary Target)

```
DATASET: opentelemetry-demo
WHERE service.name = "product-catalog"
  AND span.kind = "server"
VISUALIZE COUNT AS "Request Count",
         P95(duration_ms) AS "P95 Latency",
         COUNT(error = true) AS "Errors"
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected Impact:**

- Request volume: 2-3x increase (frontend calls it frequently)
- Latency: 1.5-2x increase (database pressure)
- Errors: Minimal to moderate (timeouts from frontend)

**Query for Product-Catalog Errors:**

```
DATASET: opentelemetry-demo
WHERE service.name = "product-catalog"
  AND error = true
VISUALIZE COUNT
BREAKDOWN exception.type
GROUP BY time(1m)
```

---

#### 6. PostgreSQL Database Impact (Tertiary)

```
DATASET: opentelemetry-demo
WHERE service.name = "postgresql-sidecar"
  AND postgresql.backends EXISTS
VISUALIZE MAX(postgresql.backends) AS "Active Connections",
         MAX(postgresql.blks_read) AS "Disk Reads",
         MAX(postgresql.blks_hit) AS "Cache Hits"
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected Impact:**

- Active connections: Slight increase (5-10 more)
- Disk reads: Moderate increase (2-3x)
- Cache hit ratio: May decrease slightly

**Cache Hit Ratio During Flood:**

```
DATASET: opentelemetry-demo
WHERE service.name = "postgresql-sidecar"
VISUALIZE (SUM(postgresql.blks_hit) / (SUM(postgresql.blks_hit) + SUM(postgresql.blks_read)) * 100) AS "Cache Hit %"
GROUP BY time(1m)
```

**Expected:** 90-95% (should remain high - minimal DB impact)

---

#### 7. Checkout Service Impact (Tertiary)

```
DATASET: opentelemetry-demo
WHERE service.name = "checkout"
  AND span.kind = "server"
VISUALIZE COUNT AS "Requests",
         P95(duration_ms) AS "P95 Latency",
         COUNT(error = true) AS "Errors"
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected Impact:**

- Requests: Moderate increase (frontend calls on some flows)
- Latency: 1.2-1.5x increase
- Errors: Minimal (mostly indirect)

---

### 🌐 COMPARISON: Envoy vs Frontend Metrics

#### 8. Envoy Proxy Passthrough Analysis

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend-proxy"
VISUALIZE COUNT AS "Requests Through Envoy",
         P95(duration_ms) AS "Envoy P95 Latency",
         COUNT(error = true) AS "Envoy Errors"
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Key Insight:**

- Envoy processes ALL requests without filtering
- Envoy errors = 0 (it's just passing traffic)
- All errors happen in frontend service (500/503)
- **This proves no rate limiting is configured**

**If rate limiting were enabled:**

```
# This query would show 429 errors if rate limiting was active
DATASET: opentelemetry-demo
WHERE service.name = "frontend-proxy"
  AND http.status_code = 429
VISUALIZE COUNT
```

**Expected with rate limiting:** Thousands of 429s
**Actual without rate limiting:** 0 (all requests pass through)

---

### 📊 BLAST RADIUS SUMMARY QUERY

#### 9. Multi-Service Impact Dashboard

```
DATASET: opentelemetry-demo
WHERE service.name IN ("frontend", "product-catalog", "checkout", "postgresql-sidecar")
  AND span.kind = "server"
VISUALIZE COUNT AS "Total Requests",
         P95(duration_ms) AS "P95 Latency",
         COUNT(error = true) AS "Error Count",
         (COUNT(error = true) / COUNT(*) * 100) AS "Error Rate %"
BREAKDOWN service.name
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected Pattern:**

| Service         | Request Increase | Latency Increase | Error Rate Increase |
| --------------- | ---------------- | ---------------- | ------------------- |
| **frontend**    | 50-100x          | 20-40x           | 5-20%               |
| product-catalog | 2-3x             | 1.5-2x           | 0.5-2%              |
| checkout        | 1.5-2x           | 1.2-1.5x         | 0-0.5%              |
| postgresql      | Minimal          | Minimal          | 0%                  |

**Key Insight:** Blast radius is **contained to frontend**, with moderate ripple effects downstream.

---

### 🚨 REAL-TIME ALERTING QUERIES

#### 10. High Error Rate Alert

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
  AND http.status_code >= 500
CALCULATE COUNT / COUNT(service.name = "frontend") * 100 AS "Error Rate %"
TIME RANGE: Last 5 minutes
```

**Alert Threshold:** Error Rate > 5%
**Severity:** Warning → Critical at >15%

---

#### 11. Latency SLO Breach

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
  AND name = "GET /"
CALCULATE P95(duration_ms)
TIME RANGE: Last 5 minutes
```

**SLO Threshold:** P95 < 100ms
**Alert Threshold:** P95 > 500ms (5x SLO breach)

---

#### 12. Service Availability

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
CALCULATE (COUNT(http.status_code < 500) / COUNT(*) * 100) AS "Availability %"
TIME RANGE: Last 5 minutes
```

**SLO:** 99.9% availability
**Alert Threshold:** <95% (severe degradation)

---

### 💡 ADVANCED ANALYSIS

#### 13. Request Flow Visualization (Trace Analysis)

```
DATASET: opentelemetry-demo
WHERE trace.parent_id NOT EXISTS  # Root spans only
  AND service.name = "frontend-proxy"
VISUALIZE COUNT
BREAKDOWN service.name, name
TIME RANGE: Last 15 minutes
```

**Shows:** Complete request flow through Envoy → Frontend → downstream services

---

#### 14. Concurrent User Load Analysis

```
DATASET: opentelemetry-demo
WHERE app.synthetic_request = true  # From load generator
  AND service.name = "frontend"
CALCULATE COUNT / 60 AS "Requests per Second"
GROUP BY time(1m)
```

**Correlate with:** Load generator user count to understand per-user impact

---

### 📉 RECOVERY VERIFICATION QUERIES

#### 15. Post-Test Recovery Confirmation

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE COUNT AS "Request Volume",
         P95(duration_ms) AS "P95 Latency",
         COUNT(error = true) AS "Errors"
GROUP BY time(1m)
TIME RANGE: Last 30 minutes
```

**Verify:**

- ✅ Request volume returns to baseline within 1-2 minutes
- ✅ Latency returns to <100ms within 2-5 minutes
- ✅ Errors drop to <1/min within 2-3 minutes

---

## 🎯 **Key Differences from Other Tests**

| Test                      | Target              | Method              | Error Type           | Envoy Involved?              |
| ------------------------- | ------------------- | ------------------- | -------------------- | ---------------------------- |
| **Frontend Flood**        | Frontend service    | High request volume | 500/503/timeout      | ✅ Yes (passes all requests) |
| **Connection Exhaustion** | PostgreSQL          | Hold connections    | "too many clients"   | ❌ No (internal DB)          |
| **IOPS Pressure**         | PostgreSQL          | Heavy I/O           | EOF, "shutting down" | ❌ No (internal DB)          |
| **Kafka Queue**           | Checkout/Accounting | Message flood       | Kafka lag, OOM       | ❌ No (internal messaging)   |

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
      '@type': type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
      stat_prefix: http_local_rate_limiter
      token_bucket:
        max_tokens: 100
        tokens_per_fill: 100
        fill_interval: 60s # 100 requests per minute
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
