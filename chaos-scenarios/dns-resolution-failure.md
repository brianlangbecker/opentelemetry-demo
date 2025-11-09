# DNS Resolution Failure - Quick Guide

**Purpose:** Demonstrate DNS resolution failures by stopping CoreDNS, causing service-to-service communication to fail.

---

## 🎯 **What It Does**

Stops CoreDNS (Kubernetes DNS service), causing:
- DNS lookup failures → `no such host` errors
- Service timeouts (~5 seconds - DNS timeout)
- Cascading failures across all services
- **No child spans** in traces (connection never established)

**Key Indicator:** Error messages contain **"lookup"**, **"no such host"**, or **"name resolution"** - DNS never resolved, so no IP address in error.

---

## ⚙️ **How to Run**

### 1. Verify CoreDNS is Running

```bash
kubectl get deployment -n kube-system coredns
kubectl get pod -n kube-system -l k8s-app=kube-dns
```

**Expected:** 2/2 pods running

### 2. Stop CoreDNS

**⚠️ WARNING:** This affects **all pods** in the cluster. Only use in test/demo clusters.

```bash
# Scale CoreDNS to 0 replicas
kubectl scale deployment coredns -n kube-system --replicas=0

# Verify it's stopped
kubectl get pod -n kube-system -l k8s-app=kube-dns
# Expected: No resources found
```

**Note:** If CoreDNS has a different name, find it first:
```bash
kubectl get deployment --all-namespaces | grep -i dns
```

### 3. Generate Load

**Via Locust:**
```bash
kubectl port-forward -n otel-demo svc/load-generator 8089:8089
# Open http://localhost:8089
# Set users: 10
# Click "Start"
```

**Or manually browse:**
- Try to view products: `http://localhost:8080`
- Try to add items to cart
- Try to checkout

**Expected:** Pages fail to load, long timeouts (5+ seconds)

### 4. Restore CoreDNS

```bash
# Restore to original replica count (usually 2)
kubectl scale deployment coredns -n kube-system --replicas=2

# Verify it's running
kubectl get pod -n kube-system -l k8s-app=kube-dns
```

---

## 📊 **What to See in Honeycomb**

### Primary Query: Frontend Error Rate

```
WHERE service.name = "frontend"
VISUALIZE COUNT
BREAKDOWN otel.status_code
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**Expected:**
- Before: Mostly `OK`
- After DNS stopped: Spike in `ERROR` status codes

---

### DNS Error Messages

```
WHERE service.name = "frontend"
  AND error = true
VISUALIZE COUNT
BREAKDOWN error.message
TIME RANGE: Last 15 minutes
```

**Expected error messages (format varies by language):**
- `dial tcp: lookup cart: no such host`
- `dial tcp: lookup productcatalog: i/o timeout`
- `Get "http://currency:8080": dial tcp: lookup currency: Temporary failure in name resolution`

**Key indicators:** Contains **"lookup"**, **"no such host"**, or **"name resolution"**

---

### Trace Analysis: No Child Spans

```
WHERE service.name = "frontend"
  AND otel.status_code = ERROR
VISUALIZE TRACES
ORDER BY timestamp DESC
LIMIT 20
```

**Click on a trace and look for:**
- ❌ **No child spans** (never reached backend services)
- ❌ Error message with DNS keywords
- ❌ Duration ~5000ms (DNS timeout)
- ❌ **No IP address** in error (DNS never resolved)

**This is DNS failure** ✅

**For comparison - Service Down (NOT DNS):**
- ✅ DNS lookup succeeded (has IP address in error)
- ❌ TCP connection refused
- Error: `dial tcp 10.0.1.5:8080: connect: connection refused`

---

### Request Latency Pattern

```
WHERE service.name = "frontend"
VISUALIZE HEATMAP(duration_ms)
GROUP BY time(30s)
```

**Expected:**
- Latency band around 5000ms (DNS timeout)
- All requests clustering at same timeout duration
- Indicates systematic DNS issue, not random slowness

---

### Service Dependency Breakdown

```
WHERE service.name = "frontend"
  AND span.kind = "client"
VISUALIZE COUNT
BREAKDOWN name, otel.status_code
GROUP BY time(1m)
```

**Expected:**
- All backend service calls failing uniformly
- DNS errors affect **all** service-to-service calls

---

## 🚨 **Alert Setup**

**Query:**
```
WHERE service.name = "frontend"
  AND error = true
  AND (error.message CONTAINS "lookup" OR error.message CONTAINS "no such host")
VISUALIZE COUNT
GROUP BY time(1m)
```

**Alert Conditions:**
- **Trigger:** COUNT > 5 errors/minute
- **Duration:** For at least 2 minutes
- **Severity:** CRITICAL

**Message:**
```
🔴 DNS Resolution Failures

Service: frontend
DNS Error Count: {{COUNT}} errors/min

Action: Check CoreDNS health and DNS service availability
```

---

## 🔍 **Key Diagnostic Patterns**

### DNS Failure Indicators ✅

- Error contains: **"lookup"**, **"no such host"**, **"name resolution"**
- **No child spans** in trace (connection never established)
- Duration = DNS timeout (~5 seconds, consistent)
- **No IP address** in error message (DNS never resolved)
- Affects **all backend services** uniformly

### NOT DNS Failure ❌

- Error shows **IP address** (DNS worked, connection failed)
- Backend spans **present** but errored (DNS worked, app failed)
- Only **specific service** fails (not all services)
- **Variable latency** (not consistent timeout)

---

## ⚠️ **Important: DNS Caching**

**DNS cache behavior varies by runtime:**

- **Go services** (frontend, checkout, cart): Cache **indefinitely** until process restart
- **Other runtimes**: Cache varies (immediate to several minutes)

**If services still work after stopping DNS:**
- Wait 2-5 minutes for cache to expire, OR
- Restart pods to clear cache:
  ```bash
  kubectl rollout restart deployment/frontend -n otel-demo
  kubectl rollout restart deployment/checkout -n otel-demo
  kubectl rollout restart deployment/cart -n otel-demo
  ```

---

## 🎓 **Understanding the Flow**

**Normal (DNS Working):**
```
Frontend → DNS lookup: cart → 10.0.1.15 ✅
         → TCP connect: 10.0.1.15:8080 ✅
         → HTTP request ✅
         → Backend span present ✅
```

**DNS Failure:**
```
Frontend → DNS lookup: cart → TIMEOUT ❌ (5 seconds)
         → Error: "no such host"
         → No TCP connection attempted
         → No backend span ❌
```

**Service Down (NOT DNS):**
```
Frontend → DNS lookup: cart → 10.0.1.15 ✅
         → TCP connect: 10.0.1.15:8080 → REFUSED ❌
         → Error: "connection refused" (has IP address)
```

---

## ✅ **Quick Checklist**

- [ ] CoreDNS verified running (2/2 pods)
- [ ] CoreDNS scaled to 0 replicas
- [ ] Load generator running or manual browsing
- [ ] Honeycomb shows: Error spike, DNS error messages
- [ ] Traces show: No child spans, ~5000ms duration
- [ ] Alert configured: Triggers on DNS error keywords
- [ ] CoreDNS restored after test

---

**Last Updated:** November 9, 2025  
**Target:** CoreDNS (Kubernetes DNS)  
**Impact:** All services using DNS for service discovery  
**Status:** Ready for testing
