# Frontend Flood & Rate Limiting - Quick Guide

**Purpose:** Demonstrate rate limiting protection by flooding the frontend with high request volume.

---

## 🎯 **What It Does**

Floods the frontend with massive homepage requests. With rate limiting configured:

- ✅ **Requests that pass:** Get HTTP 200 → Forwarded to frontend (max 500 req/min)
- ❌ **Requests that exceed:** Get HTTP 429 → Rejected by Envoy (never reach frontend)

**Result:** Frontend is protected from overload, even with high traffic.

---

## ⚙️ **Current Configuration**

**Rate Limit:** 500 requests/minute (8.33 req/sec)

**Location:** `src/frontend-proxy/envoy.tmpl.yaml`

```yaml
token_bucket:
  max_tokens: 500
  tokens_per_fill: 500
  fill_interval: 60s # 500 requests per minute
```

**To Change:** Edit the values above, rebuild image, and redeploy.

---

## 🧪 **How to Run**

### 1. Enable Flood Flag

**Via FlagD UI:**

```bash
kubectl port-forward -n otel-demo svc/flagd 4000:4000
# Open http://localhost:4000
# Set loadGeneratorFloodHomepage to "heavy" (50 requests/user)
```

**Or via ConfigMap:**

```bash
kubectl get configmap flagd-config -n otel-demo -o yaml
# Edit defaultVariant to "heavy"
# Apply: kubectl apply -f <edited-file>
```

### 2. Start Load Generator

**Via Locust UI:**

```bash
kubectl port-forward -n otel-demo svc/load-generator 8089:8089
# Open http://localhost:8089
# Set users: 25 users
# Click "Start"
```

### 3. Expected Results

**With "heavy" (50 req/user) + 25 users:**

- Total requests: ~1,250 per cycle
- **429 responses:** ~750 req/min (60%) ✅ - Rate limited by Envoy
- **200 responses:** ~500 req/min (40%) ✅ - Pass through to frontend

---

## 📊 **What to See in Honeycomb**

**Note:** Envoy creates both server-side and client-side spans. For rate limiting, monitor **server-side spans** (`span.kind = "server"`). See `frontend-proxy-otel-spans.md` for details.

### Primary Query: Count 429s (Rate Limiting)

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 5 minutes
```

**Expected:** ~750 requests/minute getting 429

---

### Compare Rate Limited vs Successful

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code IN (200, 429)
VISUALIZE COUNT
BREAKDOWN http.status_code
GROUP BY time(1m)
```

**Expected:**

- `http.status_code = 200`: ~500 req/min (successful, passed to frontend)
- `http.status_code = 429`: ~750 req/min (rate limited, rejected)

---

### Verify Frontend is Protected

**Frontend should NOT see 429s:**

```
WHERE service.name = "frontend"
  AND http.status_code = 429
VISUALIZE COUNT
```

**Expected:** 0 (ZERO!) - Frontend never sees rate-limited requests

**Frontend request volume (capped):**

```
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** Flat line at ~500 req/min (never exceeds rate limit)

**Frontend error rate (should be low):**

```
WHERE service.name = "frontend"
  AND http.status_code >= 500
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** Minimal errors (frontend protected by rate limit)

---

### Frontend Latency (Should Stay Normal)

```
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE P95(duration_ms)
GROUP BY time(1m)
```

**Expected:** P95 ~50-100ms (protected, not overloaded)

---

## 🚨 **Alert Setup**

### Alert 1: Rate Limiting Active (429s)

**Query:**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Alert Conditions:**

- **Trigger:** COUNT > 50 requests/minute
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL

**Message:**

```
🔴 Rate Limiting Active

Service: frontend-proxy
429 Count: {{COUNT}} req/min
Rate Limit: 500 req/min

Status: Service is protected ✅
Action: Review traffic source or increase rate limit
```

### Alert 2: Frontend Overload (500s)

**Query:**

```
WHERE service.name = "frontend"
  AND http.status_code >= 500
VISUALIZE COUNT
GROUP BY time(1m)
```

**Alert Conditions:**

- **Trigger:** COUNT > 10 errors/minute
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL

**Message:**

```
🔴 Frontend Service Overload

Service: frontend
Error Count: {{COUNT}} errors/min
Status Codes: 500, 503, 504

Action: Check if rate limiting is protecting frontend
```

---

## 🔧 **Feature Flag Variants**

**Flag:** `loadGeneratorFloodHomepage`

| Variant    | Requests/User | With 25 Users | Total | With Rate Limit (500/min) |
| ---------- | ------------- | ------------- | ----- | ------------------------- |
| `off`      | 0             | 0             | 0     | All pass                  |
| `light`    | 10            | 250           | 250   | All pass                  |
| `moderate` | 25            | 625           | 625   | 500 pass, 125 get 429     |
| `heavy`    | 50            | 1,250         | 1,250 | 500 pass, 750 get 429     |
| `extreme`  | 100           | 2,500         | 2,500 | 500 pass, 2,000 get 429   |

**Recommended:** Start with `moderate` (25 req/user) at 25 users = 625 total requests.

---

## 🔧 **Adjusting the Rate Limit**

### To Lower (More Protection)

**Edit:** `src/frontend-proxy/envoy.tmpl.yaml`

```yaml
token_bucket:
  max_tokens: 200 # Change from 500 to 200
  tokens_per_fill: 200
  fill_interval: 60s
```

**Rebuild and Deploy:**

```bash
# Build
docker build -t <your-registry>/frontend-proxy:rate-limit-200 \
  -f src/frontend-proxy/Dockerfile .

# Push
docker push <your-registry>/frontend-proxy:rate-limit-200

# Deploy
kubectl set image deployment/frontend-proxy \
  frontend-proxy=<your-registry>/frontend-proxy:rate-limit-200 \
  -n otel-demo
```

### To Raise (Less Protection)

Same process, increase `max_tokens` and `tokens_per_fill` values.

---

## 🎓 **Understanding the Flow**

**With Rate Limiting (Current Setup):**

```
Load Generator
    ↓ 1,250 req/min
Frontend-Proxy (Envoy)
    ├─ 500 req/min → HTTP 200 → Frontend ✅
    └─ 750 req/min → HTTP 429 → Rejected ❌
Frontend
    ↓ Only receives 500 req/min
    ✅ Protected from overload
```

**Without Rate Limiting:**

```
Load Generator
    ↓ 1,250 req/min
Frontend-Proxy (Envoy)
    ↓ Passes all requests
Frontend
    ↓ Receives 1,250 req/min
    ❌ Overwhelmed → 500/503 errors
```

---

## 📋 **Key Points**

1. **429s are NOT errors** - Rate limiting is working correctly (server-side)
   - Server-side: 429 = protection working (not an error)
   - Client-side: 429 = request rejected (is an error)
2. **Frontend is protected** - Only sees ~500 req/min, never 429s
3. **Monitor server-side spans** - Use `span.kind = "server"` in queries
4. **Query by status code** - Use `http.status_code = 429`, not `error = true`

---

## ✅ **Quick Checklist**

- [ ] Rate limit configured: 500 req/min
- [ ] Flood flag set to "heavy" (50 req/user)
- [ ] Load generator running: 25+ users
- [ ] Honeycomb shows 429s: ~750 req/min in frontend-proxy
- [ ] Frontend shows 0 429s: Protected ✅
- [ ] Frontend shows minimal 500s: Protected ✅
- [ ] Alert configured: Triggers on >50 429/min

---

**Last Updated:** November 9, 2025  
**Rate Limit:** 500 requests/minute  
**Flag:** `loadGeneratorFloodHomepage`  
**Status:** Active and protecting frontend service
