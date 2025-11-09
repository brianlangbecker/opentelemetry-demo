# Why HTTP 429 is NOT Considered an Error in OpenTelemetry

## 🎯 **The Answer: Server-Side vs Client-Side**

According to [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/http/http-spans/), **HTTP 429 is treated differently depending on perspective:**

### **Server-Side (Envoy/frontend-proxy): 429 is NOT an Error** ✅

**Why:** When a server sends a 429 response, it's **successfully enforcing rate limits** - the server is working as intended!

```
Envoy (Server) → Returns 429
Status: ✅ SUCCESS (rate limiting working correctly)
Span Status: OK (not ERROR)
```

**Reasoning:**

- The server is functioning correctly
- Rate limiting is a **feature**, not a bug
- Marking it as an error would create false alarms
- The server is protecting itself from overload

### **Client-Side (Load Generator): 429 IS an Error** ❌

**Why:** When a client receives a 429, the request was **rejected** - the operation failed!

```
Load Generator (Client) → Receives 429
Status: ❌ ERROR (request rejected)
Span Status: ERROR
```

**Reasoning:**

- The client's request was unsuccessful
- The operation failed from the client's perspective
- This is a real error for the client

---

## 📊 **How to Query for 429s in Honeycomb**

### ❌ **This Won't Work (429s are NOT in error queries):**

```
WHERE service.name = "frontend-proxy"
  AND error = true
```

**Result:** 0 results (429s don't have `error = true`)

---

### ✅ **This WILL Work (Query by status code):**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

**Result:** Shows all 429 responses

---

### ✅ **Alternative: Query All Non-200 Status Codes:**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code >= 400
  AND http.status_code != 200
VISUALIZE COUNT
GROUP BY http.status_code
```

**Result:** Shows 429, 404, 500, etc. (all non-success codes)

---

## 🔍 **Why This Design Makes Sense**

### **Server Perspective (Envoy):**

| Status Code | Meaning             | Is Error? | Why                                              |
| ----------- | ------------------- | --------- | ------------------------------------------------ |
| 200         | Success             | ❌ No     | Request processed                                |
| 429         | Rate Limited        | ❌ No     | **Server protecting itself (working correctly)** |
| 500         | Server Error        | ✅ Yes    | Server malfunction                               |
| 503         | Service Unavailable | ✅ Yes    | Server can't handle request                      |

**429 = "I'm working correctly by rejecting excess traffic"**

### **Client Perspective (Load Generator):**

| Status Code | Meaning             | Is Error? | Why                         |
| ----------- | ------------------- | --------- | --------------------------- |
| 200         | Success             | ❌ No     | Request succeeded           |
| 429         | Rate Limited        | ✅ Yes    | **My request was rejected** |
| 500         | Server Error        | ✅ Yes    | Server failed               |
| 503         | Service Unavailable | ✅ Yes    | Service unavailable         |

**429 = "My request failed"**

---

## 🎓 **OpenTelemetry Semantic Conventions**

From the [OTel HTTP Span Conventions](https://opentelemetry.io/docs/specs/semconv/http/http-spans/):

> **Server-side:** For HTTP status codes in the 4xx range (except 401 Unauthorized), the span status SHOULD be left unset. These codes indicate client errors, not server errors.

> **Client-side:** For HTTP status codes in the 4xx-5xx range, the span status SHOULD be set to ERROR.

**Key Point:** 429 is a 4xx code, so:

- **Server-side:** Status left unset (not ERROR) ✅
- **Client-side:** Status set to ERROR ✅

---

## 📈 **Practical Queries for Rate Limiting**

### 1. **Count 429s (Server-Side):**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 429
VISUALIZE COUNT
GROUP BY time(1m)
```

### 2. **Compare 200 vs 429:**

```
WHERE service.name = "frontend-proxy"
CALCULATE success = COUNT_IF(http.status_code = 200)
CALCULATE rate_limited = COUNT_IF(http.status_code = 429)
VISUALIZE success, rate_limited
GROUP BY time(1m)
```

### 3. **Client-Side Errors (Load Generator):**

```
WHERE service.name = "load-generator"
  AND error = true
VISUALIZE COUNT
GROUP BY time(1m)
```

**This WILL show 429s** because the client sees them as errors!

### 4. **All Non-Success Status Codes:**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code >= 400
VISUALIZE COUNT
GROUP BY http.status_code
```

---

## ✅ **Summary**

**Why 429 isn't in error queries:**

- ✅ **Server-side (Envoy):** 429 = Server working correctly (rate limiting active)
- ✅ **OpenTelemetry convention:** 4xx codes (except 401) are NOT server errors
- ✅ **Design intent:** Prevents false alarms when rate limiting is working

**How to find 429s:**

- ✅ Query by `http.status_code = 429` (not `error = true`)
- ✅ Client-side (load-generator) WILL show 429s as errors
- ✅ Use status code queries, not error queries

**This is correct behavior!** Rate limiting is a feature, not a bug. 🎯
