# Envoy Rate Limiting - Quick Guide

**Purpose:** Protect frontend service from overload by limiting requests at the Envoy proxy layer.

---

## 🎯 **What It Does**

Envoy (`frontend-proxy`) enforces a rate limit of **500 requests/minute**. When exceeded:
- ✅ Requests that pass: Get HTTP 200 → Forwarded to frontend
- ❌ Requests that exceed: Get HTTP 429 → Rejected immediately (never reach frontend)

**Result:** Frontend is protected from overload, even with high traffic.

---

## ⚙️ **Current Configuration**

**Rate Limit:** 500 requests/minute (8.33 req/sec)

**Location:** `src/frontend-proxy/envoy.tmpl.yaml`

```yaml
token_bucket:
  max_tokens: 500
  tokens_per_fill: 500
  fill_interval: 60s  # 500 requests per minute
```

**To Change:** Edit the values above, rebuild image, and redeploy.

---

## 🧪 **How to Test**

### 1. Enable Flood Traffic

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
- **429 responses:** ~750 req/min (60%) ✅
- **200 responses:** ~500 req/min (40%) ✅

---

## 📊 **What to See in Honeycomb**

**Note:** Envoy creates both server-side and client-side spans. For rate limiting, monitor **server-side spans** (`span.kind = "server"`). See `frontend-proxy-otel-spans.md` for details.

### Primary Query: Count 429s

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
CALCULATE success = COUNT_IF(http.status_code = 200)
CALCULATE limited = COUNT_IF(http.status_code = 429)
VISUALIZE success, limited
GROUP BY time(1m)
```

**Expected:**
- `success`: ~500 req/min (green line)
- `limited`: ~750 req/min (red line)

---

### Verify Frontend is Protected

```
WHERE service.name = "frontend"
  AND http.status_code = 429
VISUALIZE COUNT
```

**Expected:** 0 (ZERO!) - Frontend never sees rate-limited requests

```
WHERE service.name = "frontend"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** Flat line at ~500 req/min (never exceeds rate limit)

---

## 🚨 **Alert Setup**

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

---

## 🔧 **Adjusting the Rate Limit**

### To Lower (More Protection)

**Edit:** `src/frontend-proxy/envoy.tmpl.yaml`
```yaml
token_bucket:
  max_tokens: 200  # Change from 500 to 200
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

## 📋 **Key Points**

1. **429s are NOT errors** - Rate limiting is working correctly (server-side)
   - See `why-429-not-error.md` for technical details
2. **Frontend is protected** - Only sees ~500 req/min, never 429s
3. **Monitor server-side spans** - Use `span.kind = "server"` in queries
4. **Query by status code** - Use `http.status_code = 429`, not `error = true`

---

## 🎓 **Understanding the Flow**

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

---

## ✅ **Quick Checklist**

- [ ] Rate limit configured: 500 req/min
- [ ] Flood flag set to "heavy" (50 req/user)
- [ ] Load generator running: 25+ users
- [ ] Honeycomb query shows 429s: ~750 req/min
- [ ] Frontend shows 0 429s: Protected ✅
- [ ] Alert configured: Triggers on >50 429/min

---

**Last Updated:** November 9, 2025  
**Rate Limit:** 500 requests/minute  
**Status:** Active and protecting frontend service

