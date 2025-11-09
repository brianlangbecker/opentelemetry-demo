# Frontend-Proxy OpenTelemetry: Server-Side vs Client-Side

## 🎯 **The Answer: BOTH Server-Side AND Client-Side**

Envoy (`frontend-proxy`) creates **BOTH** types of spans because it acts as:

1. **Server** (receiving requests from load generator)
2. **Client** (making requests to upstream services like frontend)

The key configuration is:

```yaml
spawn_upstream_span: true # Creates separate spans for upstream requests
```

---

## 📊 **Span Structure with "Heavy" Setting**

### **Request Flow:**

```
Load Generator (Client)
    ↓ HTTP Request
Frontend-Proxy (Envoy)
    ├─ Server-Side Span (receiving from load generator)
    │   ├─ Rate limiting check (429 if exceeded)
    │   └─ HTTP status: 429 or 200
    │
    └─ Client-Side Span (calling frontend) [IF request passed rate limit]
        ├─ HTTP request to frontend:8080
        └─ HTTP status: 200, 500, 503, or 0
```

---

## 🔍 **Server-Side Span (Envoy as Server)**

**What it is:** Envoy receiving requests from the load generator

**Span Kind:** `server` (or `internal`)

**What you see:**

- ✅ **HTTP 429** (rate limiting active) - **NOT an error**
- ✅ **HTTP 200** (request passed rate limit)
- ✅ **HTTP status_code** attribute
- ✅ **Duration:** Very short for 429 (< 1ms), longer for 200

**Query:**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"  # or omit, defaults to server
  AND http.status_code = 429
VISUALIZE COUNT
```

**With "heavy" setting:**

- ~750 req/min get 429 (rate limited) ✅
- ~500 req/min get 200 (passed through) ✅

**Error Status:** 429 is **NOT** an error (rate limiting working correctly)

---

## 🔍 **Client-Side Span (Envoy as Client)**

**What it is:** Envoy making requests to upstream services (frontend, etc.)

**Span Kind:** `client`

**What you see:**

- ✅ **HTTP 200** (frontend responded successfully)
- ❌ **HTTP 500** (frontend error)
- ❌ **HTTP 503** (frontend unavailable)
- ❌ **HTTP 0** (connection refused/timeout) - **IS an error**

**Query:**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "client"
  AND http.status_code = 0
VISUALIZE COUNT
```

**With "heavy" setting:**

- If frontend is overloaded: Status code 0 (connection refused/timeout) ❌
- If frontend is healthy: Status code 200 ✅

**Error Status:** Status code 0 **IS** an error (connection failed)

---

## 📈 **What "Heavy" Setting Drives**

### **Server-Side (Primary Impact):**

**Traffic:** 1,250 requests/minute from load generator

**Result:**

- 500 req/min → Pass rate limit → Get HTTP 200 (server-side)
- 750 req/min → Hit rate limit → Get HTTP 429 (server-side)

**This is where rate limiting shows up!**

---

### **Client-Side (Secondary Impact):**

**Traffic:** Only the 500 req/min that passed rate limit

**Result:**

- If frontend healthy: 500 req/min → HTTP 200 (client-side)
- If frontend overloaded: Some → HTTP 0 or 500 (client-side)

**This is where frontend overload shows up!**

---

## 🎓 **Key Differences**

| Aspect                      | Server-Side Span                 | Client-Side Span                    |
| --------------------------- | -------------------------------- | ----------------------------------- |
| **Role**                    | Envoy as server (receiving)      | Envoy as client (calling upstream)  |
| **Span Kind**               | `server`                         | `client`                            |
| **429 Status**              | ✅ Shows up (rate limiting)      | ❌ Never shows (429 stops here)     |
| **429 is Error?**           | ❌ No (rate limiting working)    | N/A                                 |
| **Status Code 0**           | ❌ Rare (only if load gen fails) | ✅ Shows (frontend down/overloaded) |
| **Status Code 0 is Error?** | ✅ Yes                           | ✅ Yes                              |
| **Shows Frontend Health**   | ❌ No (rate limit blocks)        | ✅ Yes (calls frontend)             |

---

## 📊 **Honeycomb Queries**

### **1. Server-Side: Rate Limiting (429s)**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected with "heavy":** ~750 req/min

---

### **2. Server-Side: Successful Requests (200s)**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 200
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected with "heavy":** ~500 req/min (rate limit)

---

### **3. Client-Side: Frontend Connection Issues (0s)**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "client"
  AND http.target = "/"
  AND http.status_code = 0
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** 0 if frontend healthy, > 0 if frontend overloaded

---

### **4. Client-Side: Frontend Errors (500s)**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "client"
  AND http.target = "/"
  AND http.status_code = 500
VISUALIZE COUNT
GROUP BY time(1m)
```

**Expected:** 0 if frontend healthy, > 0 if frontend overloaded

---

### **5. Compare Server vs Client Spans**

```
WHERE service.name = "frontend-proxy"
CALCULATE server_429 = COUNT_IF(span.kind = "server" AND http.status_code = 429)
CALCULATE client_0 = COUNT_IF(span.kind = "client" AND http.status_code = 0)
VISUALIZE server_429, client_0
GROUP BY time(1m)
```

**Interpretation:**

- `server_429` high → Rate limiting active ✅
- `client_0` high → Frontend is down/overloaded ❌

---

## ✅ **Answer to Your Question**

**"Should the heavy setting be driving server or client side OTel?"**

**Answer: BOTH, but primarily SERVER-SIDE**

### **Server-Side (Primary):**

- ✅ **This is where rate limiting (429) shows up**
- ✅ Heavy setting generates 1,250 req/min
- ✅ 750 get rate limited (429) - server-side span
- ✅ 500 pass through (200) - server-side span

### **Client-Side (Secondary):**

- ✅ **This is where frontend health shows up**
- ✅ Only 500 req/min reach client-side (those that passed rate limit)
- ✅ If frontend overloaded: Status code 0 or 500 - client-side span
- ✅ If frontend healthy: Status code 200 - client-side span

---

## 🎯 **What to Monitor**

### **For Rate Limiting:**

**Monitor SERVER-SIDE spans:**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "server"
  AND http.status_code = 429
```

### **For Frontend Health:**

**Monitor CLIENT-SIDE spans:**

```
WHERE service.name = "frontend-proxy"
  AND span.kind = "client"
  AND http.target = "/"
  AND (http.status_code = 0 OR http.status_code >= 500)
```

---

## 📋 **Summary**

**With "heavy" setting:**

1. **Server-Side Spans:**

   - 1,250 req/min total
   - 750 get 429 (rate limited) ✅ Expected
   - 500 get 200 (passed) ✅ Expected

2. **Client-Side Spans:**
   - 500 req/min total (only those that passed rate limit)
   - Should all be 200 if frontend healthy ✅
   - Will be 0 or 500 if frontend overloaded ❌

**The heavy setting primarily drives SERVER-SIDE spans (where rate limiting appears), but also creates CLIENT-SIDE spans (where frontend health appears).**

---

**Last Updated:** November 9, 2025  
**Related:** `frontend-flood-rate-limiting.md` (rate limiting guide)
