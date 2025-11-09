# Envoy Rate Limit Alert Setup (HTTP 429)

**Alert Type:** Critical - Service Protection Active  
**Signal:** Rate limiting is protecting the service from overload  
**Severity:** 🔴 High (indicates traffic spike or attack)

---

## 🚨 **Honeycomb Alert Configuration**

### Alert 1: Rate Limit Threshold Exceeded (Critical)

**Purpose:** Detect when Envoy is actively rate limiting traffic

**Query:**

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend-proxy"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Alert Conditions:**

- **Trigger:** COUNT > 50 requests/minute
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL
- **Description:** "Envoy rate limit active - rejecting >50 req/min with HTTP 429"

**Notification Message:**

```
🔴 CRITICAL: Envoy Rate Limiting Active

Service: frontend-proxy
Status: HTTP 429 (Too Many Requests)
Rate: {{COUNT}} requests rejected in last minute
Threshold: 500 requests/minute total capacity

Impact: {{PERCENT}}% of traffic is being rate limited
Action: Investigate traffic source and consider scaling
```

---

### Alert 2: Rate Limit Saturation (Warning)

**Purpose:** Early warning before rate limit is fully saturated

**Query:**

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend-proxy"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Alert Conditions:**

- **Trigger:** COUNT > 25 requests/minute
- **Duration:** For at least 3 minutes
- **Severity:** WARNING
- **Description:** "Approaching Envoy rate limit - 429 errors increasing"

---

### Alert 3: Rate Limit Percentage (Advanced)

**Purpose:** Alert based on percentage of traffic rate limited

**Query:**

```
DATASET: opentelemetry-demo
WHERE service.name = "frontend-proxy"
CALCULATE rate_limited = COUNT_IF(http.status_code = 429)
CALCULATE total = COUNT
CALCULATE pct_limited = (rate_limited / total) * 100
VISUALIZE pct_limited
GROUP BY time(1m)
```

**Alert Conditions:**

- **Trigger:** pct_limited > 20%
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL
- **Description:** "More than 20% of traffic is being rate limited"

---

## 🔍 **Understanding the Traffic Flow**

### What Happens When Rate Limit is Hit:

```
┌─────────────────┐
│  Load Generator │
│   (Locust)      │
└────────┬────────┘
         │
         │ HTTP Request
         ▼
┌─────────────────────────────────────────────────┐
│  Frontend-Proxy (Envoy)                         │
│  - Rate Limit: 500 req/min                      │
│  - Token Bucket: 500 tokens                     │
│                                                  │
│  IF tokens available:                           │
│    ✅ Pass through → Frontend                   │
│  ELSE:                                          │
│    ❌ Return HTTP 429 immediately               │
│    ❌ Request NEVER reaches frontend            │
└─────────────────────────────────────────────────┘
         │
         │ (Only if NOT rate limited)
         ▼
┌─────────────────┐
│   Frontend      │
│  (Python/Flask) │
│                 │
│  ✅ Processes   │
│     request     │
└─────────────────┘
```

---

## 📊 **Downstream Visibility**

### Question: Will we see issues in Frontend?

**Answer: NO - 429 errors do NOT reach the frontend service**

| Service            | What You See                         | Why                                   |
| ------------------ | ------------------------------------ | ------------------------------------- |
| **frontend-proxy** | ✅ HTTP 429 errors                   | Envoy returns 429 immediately         |
| **frontend-proxy** | ✅ `x-local-rate-limit: true` header | Added by Envoy rate limit filter      |
| **frontend-proxy** | ✅ High request count                | Sees ALL requests (passed + rejected) |
| **frontend**       | ❌ NO 429 errors                     | Never receives rate-limited requests  |
| **frontend**       | ⚠️ Lower request count               | Only sees requests that passed Envoy  |
| **Load Generator** | ✅ HTTP 429 responses                | Receives 429 from Envoy               |

---

## 🎯 **What You'll Observe During Rate Limiting**

### In frontend-proxy (Envoy):

**Expected Metrics:**

```
http.status_code = 200:  ~500 req/min  (passed through)
http.status_code = 429:  ~100+ req/min (rate limited)
Total requests:          ~600+ req/min
```

**Spans/Traces:**

- Short duration (< 1ms) - Envoy returns immediately
- No downstream calls
- `http.status_code = 429`
- `x-local-rate-limit = true` header

### In frontend (Python/Flask):

**Expected Metrics:**

```
http.status_code = 200:  ~500 req/min (only successful requests)
http.status_code = 429:  0 req/min    (NEVER sees these)
Total requests:          ~500 req/min (capped by Envoy)
```

**Behavior:**

- Frontend operates normally at ~500 req/min
- NO 429 errors in frontend logs/traces
- NO overload or resource exhaustion
- Service is PROTECTED by Envoy

### In Load Generator (Locust):

**Expected Stats:**

```
Total requests sent:     625 req/cycle
Successful (200):        500 req/cycle
Rate limited (429):      125 req/cycle
Success rate:            80%
```

---

## 🔬 **Honeycomb Queries for Investigation**

### 1. Rate Limit Impact by Endpoint

**See which endpoints are being rate limited:**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY http.target
ORDER BY COUNT DESC
```

### 2. Rate Limit vs Success Comparison

**Compare rate limited vs successful requests:**

```
WHERE service.name = "frontend-proxy"
CALCULATE success = COUNT_IF(http.status_code = 200)
CALCULATE limited = COUNT_IF(http.status_code = 429)
VISUALIZE success, limited
GROUP BY time(1m)
```

### 3. Frontend Request Volume During Rate Limiting

**Verify frontend is protected:**

```
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** Flat line at ~500 req/min (never spikes above rate limit)

### 4. Load Generator Error Rate

**See impact from client perspective:**

```
WHERE service.name = "load-generator"
CALCULATE total = COUNT
CALCULATE errors = COUNT_IF(http.status_code = 429)
CALCULATE error_pct = (errors / total) * 100
VISUALIZE error_pct
GROUP BY time(1m)
```

### 5. Response Time Comparison

**429s are FAST (Envoy returns immediately):**

```
WHERE service.name = "frontend-proxy"
CALCULATE avg_200 = AVG(IF(http.status_code = 200, duration_ms))
CALCULATE avg_429 = AVG(IF(http.status_code = 429, duration_ms))
VISUALIZE avg_200, avg_429
GROUP BY time(1m)
```

**Expected:** 429 duration << 200 duration (sub-millisecond)

---

## 🎓 **Learning Outcomes**

### What This Demonstrates:

1. **Rate Limiting is Perimeter Defense**

   - Envoy blocks traffic BEFORE it reaches the application
   - Frontend never sees the overload

2. **429 Errors are NOT Application Errors**

   - They are infrastructure-level protection
   - Indicate capacity limits, not bugs

3. **Blast Radius is CONTAINED**

   - Only frontend-proxy shows 429 metrics
   - Downstream services (frontend, checkout, etc.) operate normally
   - Database connections stay within limits

4. **Client-Side Error Handling Required**
   - Clients receive 429 and must implement retry logic
   - Locust will show degraded success rate

---

## 📋 **Alert Response Playbook**

### When Alert Fires:

1. **Verify Rate Limit is Protecting (Not Breaking) Service**

   ```
   WHERE service.name = "frontend"
     AND http.status_code >= 500
   VISUALIZE COUNT
   ```

   - If no 5xx errors → Rate limit is working as designed ✅
   - If 5xx errors present → Investigate application issues ❌

2. **Check Traffic Source**

   ```
   WHERE service.name = "frontend-proxy"
     AND http.status_code = 429
   VISUALIZE COUNT
   GROUP BY http.client_ip
   ```

   - Single IP → Possible misbehaving client or attack
   - Distributed → Legitimate traffic spike

3. **Review Frontend Resource Utilization**

   ```
   WHERE service.name = "frontend"
   VISUALIZE AVG(system.cpu.utilization), AVG(system.memory.utilization)
   GROUP BY time(1m)
   ```

   - Low utilization → Rate limit is working, consider increasing limit
   - High utilization → Rate limit is preventing overload ✅

4. **Consider Action**
   - **Legitimate traffic spike:** Increase rate limit or scale frontend
   - **Attack/abuse:** Keep rate limit, block offending IPs
   - **Load test:** Expected behavior, no action needed

---

## 🛠️ **Adjusting the Rate Limit**

### To Increase Rate Limit (e.g., to 1000 req/min):

**Edit:** `src/frontend-proxy/envoy.tmpl.yaml`

```yaml
token_bucket:
  max_tokens: 1000
  tokens_per_fill: 1000
  fill_interval: 60s # 1000 requests per minute
```

**Apply:**

```bash
kubectl create configmap envoy-config -n otel-demo \
  --from-file=envoy.tmpl.yaml=src/frontend-proxy/envoy.tmpl.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/frontend-proxy -n otel-demo
```

### To Disable Rate Limiting:

**Option 1: Remove the filter entirely from `envoy.tmpl.yaml`**

**Option 2: Set very high limit (effectively unlimited):**

```yaml
token_bucket:
  max_tokens: 1000000
  tokens_per_fill: 1000000
  fill_interval: 60s # 1M req/min
```

---

## 📚 **Related Tests**

- **Frontend Flood Homepage:** `chaos-scenarios/frontend-flood-homepage.md`
- **Connection Exhaustion:** `chaos-scenarios/postgres-disk-iops-pressure.md`
- **IOPS Pressure:** `infra/postgres-chaos/docs/IOPS-BLAST-RADIUS-TEST-RESULTS.md`

---

## ✅ **Success Criteria**

**You know rate limiting is working when:**

1. ✅ Honeycomb shows HTTP 429 in `frontend-proxy`
2. ✅ Honeycomb shows `x-local-rate-limit: true` header
3. ✅ Frontend request volume stays ≤ 500 req/min
4. ✅ Frontend has NO 429 errors (0 count)
5. ✅ Frontend has NO 5xx errors (protected from overload)
6. ✅ Load generator shows ~80% success rate (20% rate limited)

---

**Last Updated:** November 9, 2025  
**Author:** OpenTelemetry Demo Chaos Engineering  
**Environment:** Kubernetes with Envoy 1.34
