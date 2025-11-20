# Frontend Flood & Rate Limiting

Demonstrate rate limiting protection by flooding the frontend with high request volume.

## What It Does

Floods the frontend with massive homepage requests using Envoy rate limiting:

- ✅ **Requests within limit:** HTTP 200 → Pass through (max 500 req/min)
- ❌ **Requests exceeding limit:** HTTP 429 → Rejected by Envoy

**Result:** Frontend protected from overload despite high traffic.

---

## Quick Start

**1. Enable flood flag:**
```
http://localhost:4000 (FlagD UI)
Set loadGeneratorFloodHomepage = "heavy"
```

**2. Start load test:**
```
http://localhost:8089 (Locust)
Users: 25
```

**3. Expected with 25 users + "heavy" (50 req/user):**
- Total: ~1,250 req/min
- HTTP 200: ~500 req/min (40% pass)
- HTTP 429: ~750 req/min (60% rate limited)

---

## Current Configuration

**Rate Limit:** 500 requests/minute (8.33 req/sec)

**Location:** `src/frontend-proxy/envoy.tmpl.yaml`

```yaml
token_bucket:
  max_tokens: 500
  tokens_per_fill: 500
  fill_interval: 60s
```

---

## Monitoring Queries

### Count 429s (Rate Limiting Active)

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** ~750 req/min getting 429

---

### Compare Rate Limited vs Successful

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code IN (200, 429)
VISUALIZE COUNT
GROUP BY http.status_code, time(1m)
```

**Expected:**
- `200`: ~500 req/min (pass through)
- `429`: ~750 req/min (rejected)

---

### Verify Frontend is Protected

**Frontend should see ZERO 429s:**
```
WHERE service.name = "frontend"
  AND http.status_code = 429
VISUALIZE COUNT
```

**Expected:** 0 (frontend never sees rate-limited requests)

**Frontend request volume (capped):**
```
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** Flat line at ~500 req/min (never exceeds limit)

**Frontend latency (should stay normal):**
```
WHERE service.name = "frontend"
  AND name = "GET /"
VISUALIZE P95(duration_ms)
GROUP BY time(1m)
```

**Expected:** P95 ~50-100ms (protected, not overloaded)

---

## Alerts

### Alert 1: High Rate Limiting

**Query:**
```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** COUNT > 50 req/min for 2 minutes
- **Severity:** WARNING

**Notification:**
```
⚠️ Rate Limiting Active

Service: frontend-proxy
429 Count: {{COUNT}} req/min
Rate Limit: 500 req/min

Status: Service is protected ✅
Action: Review traffic source or adjust limit if needed
```

---

### Alert 2: Frontend Overload

**Query:**
```
WHERE service.name = "frontend"
  AND http.status_code >= 500
VISUALIZE COUNT
GROUP BY time(1m)
```

**Trigger:**
- **Threshold:** COUNT > 10 errors/min for 2 minutes
- **Severity:** CRITICAL

---

## Feature Flag Variants

| Variant | Requests/User | With 25 Users | Result |
|---------|---------------|---------------|--------|
| `off` | 0 | 0 | All pass |
| `light` | 10 | 250 | All pass |
| `moderate` | 25 | 625 | 500 pass, 125 get 429 |
| `heavy` | 50 | 1,250 | 500 pass, 750 get 429 |
| `extreme` | 100 | 2,500 | 500 pass, 2,000 get 429 |

**Recommended:** Start with `moderate` (625 total requests).

---

## Adjusting Rate Limit

**Edit:** `src/frontend-proxy/envoy.tmpl.yaml`

**Lower limit (more protection):**
```yaml
token_bucket:
  max_tokens: 200  # Reduced from 500
  tokens_per_fill: 200
  fill_interval: 60s
```

**Rebuild and deploy:**
```bash
docker build -t <registry>/frontend-proxy:custom src/frontend-proxy/
docker push <registry>/frontend-proxy:custom
kubectl set image deployment/frontend-proxy \
  frontend-proxy=<registry>/frontend-proxy:custom -n otel-demo
```

---

## Understanding the Flow

**With Rate Limiting (Current):**
```
Load Generator (1,250 req/min)
    ↓
Frontend-Proxy (Envoy)
    ├─ 500 req/min → HTTP 200 → Frontend ✅
    └─ 750 req/min → HTTP 429 → Rejected ❌
Frontend
    ↓ Only receives 500 req/min
    ✅ Protected from overload
```

**Without Rate Limiting:**
```
Load Generator (1,250 req/min)
    ↓
Frontend-Proxy (passes all)
    ↓
Frontend (receives 1,250 req/min)
    ❌ Overwhelmed → 500/503 errors
```

---

## Key Points

1. **429s are protection working** (not errors when monitoring server-side)
2. **Frontend is protected** - Only sees ~500 req/min, never 429s
3. **Monitor server-side spans** - Use `span.kind = "server"` in queries
4. **Query by status code** - Use `http.status_code = 429`, not `error = true`

---

## Quick Checklist

- [ ] Flood flag set to "heavy"
- [ ] Load generator: 25+ users
- [ ] Honeycomb shows ~750 429/min (frontend-proxy)
- [ ] Frontend shows 0 429s (protected)
- [ ] Frontend shows minimal 500s (protected)
- [ ] Alert triggers on >50 429/min

---

**Rate Limit:** 500 req/min | **Flag:** `loadGeneratorFloodHomepage` | **Status:** Active protection
