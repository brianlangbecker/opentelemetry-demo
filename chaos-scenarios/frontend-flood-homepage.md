# Frontend Flood Homepage - Quick Guide

**Purpose:** Demonstrate service overload by flooding the frontend with high request volume.

---

## 🎯 **What It Does**

Floods the frontend service with massive homepage requests, causing:
- CPU and memory exhaustion
- Connection pool saturation
- Increased latency and timeouts
- Service degradation (500/503 errors)

**Note:** With rate limiting configured (500 req/min), excess requests get HTTP 429 from Envoy instead of reaching frontend.

---

## ⚙️ **How to Run**

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
- **With rate limit (500 req/min):** ~750 get 429, ~500 reach frontend
- **Without rate limit:** All 1,250 reach frontend → overload

---

## 📊 **What to See in Honeycomb**

### Primary Query: Frontend Request Volume

```
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:**
- Baseline: 50-100 requests/min
- During flood: 5,000-10,000 requests/min (without rate limit)
- With rate limit: ~500 requests/min (protected)

---

### Frontend Error Rate

```
WHERE service.name = "frontend"
  AND http.status_code >= 500
VISUALIZE COUNT
GROUP BY http.status_code, time(1m)
```

**Expected Status Codes:**
- `500` Internal Server Error (service overwhelmed)
- `503` Service Unavailable (connection pool exhausted)
- `504` Gateway Timeout (response too slow)

**Baseline vs Flood:**
- Baseline: <1 error/min (<0.1%)
- Flood: 50-200 errors/min (5-20%) - without rate limit
- With rate limit: Minimal errors (frontend protected)

---

### Frontend Latency Degradation

```
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

**Expected:**
- Baseline: P95 ~50ms
- During flood: P95 1,000-2,000ms (20-40x increase) - without rate limit
- With rate limit: P95 ~50-100ms (protected)

---

### Envoy Rate Limiting (if configured)

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** ~750 requests/minute getting 429 (with "heavy" + 25 users)

📋 **See:** `chaos-scenarios/envoy-rate-limiting.md` for rate limit details.

---

### Downstream Impact: Product-Catalog

```
WHERE service.name = "product-catalog"
  AND span.kind = "server"
VISUALIZE COUNT, P95(duration_ms)
GROUP BY time(1m)
```

**Expected:** 2-3x request increase, 1.5-2x latency increase

---

## 🚨 **Alert Setup**

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

Action: Check request volume and consider rate limiting
```

---

## 🔧 **Feature Flag Variants**

**Flag:** `loadGeneratorFloodHomepage`

| Variant    | Requests/User | With 25 Users | Impact                   |
| ---------- | ------------- | ------------- | ------------------------ |
| `off`      | 0             | 0             | Normal behavior          |
| `light`    | 10            | 250           | ⚠️ Light                 |
| `moderate` | 25            | 625           | 🟡 Moderate              |
| `heavy`    | 50            | 1,250         | 🔴 Severe                |
| `extreme`  | 100           | 2,500         | 💥 Connection exhaustion |

**Recommended:** Start with `moderate` (25 req/user) at 25 users = 625 total requests.

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

## 📋 **Key Indicators**

**What you'll see:**
- ✅ Request volume: 50-100x increase
- ✅ Error rate: 5-20% (without rate limit)
- ✅ Latency: 20-40x increase (without rate limit)
- ✅ CPU/Memory: 8-16x increase (without rate limit)

**What you won't see (with rate limit):**
- ❌ Frontend overload (protected by rate limit)
- ❌ High error rate in frontend (rate limit blocks excess)
- ❌ Extreme latency (rate limit caps traffic)

---

## ✅ **Quick Checklist**

- [ ] Flood flag set to "heavy" (50 req/user)
- [ ] Load generator running: 25+ users
- [ ] Honeycomb shows: Request volume spike
- [ ] With rate limit: 429s in frontend-proxy, frontend protected
- [ ] Without rate limit: 500/503 errors in frontend
- [ ] Alert configured: Triggers on >10 errors/min

---

**Last Updated:** November 9, 2025  
**Flag:** `loadGeneratorFloodHomepage`  
**Rate Limit:** 500 req/min (protects frontend)  
**Status:** Active and ready for testing
