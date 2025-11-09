# HTTP Status Code 0 in Frontend-Proxy

## 🎯 **What is HTTP Status Code 0?**

**HTTP status code 0 is NOT a valid HTTP status code.** It indicates that **no HTTP response was received at all** - the request failed before a response could be sent.

---

## 🔍 **What Causes Status Code 0 in Frontend-Proxy (Envoy)?**

### **1. Connection Refused (Most Common)**

**Scenario:** Envoy cannot connect to the upstream service (frontend)

```
Client → Envoy (frontend-proxy) → ❌ Cannot connect to frontend:8080
Result: Status Code 0
```

**Common Causes:**

- Frontend service is down
- Frontend pod crashed/restarting
- Port mismatch (Envoy trying wrong port)
- Network policy blocking connection
- Service discovery failure (DNS not resolving)

**Error Pattern:**

```
Error: "connection refused"
Error: "dial tcp: connect: connection refused"
```

---

### **2. Connection Timeout**

**Scenario:** Envoy connects but upstream doesn't respond in time

```
Client → Envoy → Frontend (no response within timeout)
Result: Status Code 0
```

**Common Causes:**

- Frontend is overloaded (not responding)
- Frontend is deadlocked/frozen
- Network latency too high
- Envoy timeout too short

**Error Pattern:**

```
Error: "context deadline exceeded"
Error: "timeout"
Duration: Matches Envoy timeout setting
```

---

### **3. Network Error**

**Scenario:** Network layer failure before HTTP response

```
Client → Envoy → ❌ Network failure
Result: Status Code 0
```

**Common Causes:**

- Network partition
- Firewall blocking
- Network policy misconfiguration
- Pod network issues

**Error Pattern:**

```
Error: "network unreachable"
Error: "no route to host"
```

---

### **4. Client Aborted Request**

**Scenario:** Client cancels request before response

```
Client → Envoy → (client cancels) → No response
Result: Status Code 0
```

**Common Causes:**

- Browser/user cancels request
- Load generator timeout
- Client-side timeout
- Connection closed by client

**Error Pattern:**

```
Error: "request canceled"
Error: "context canceled"
```

---

### **5. Envoy Configuration Error**

**Scenario:** Envoy misconfiguration prevents request forwarding

```
Client → Envoy → ❌ Configuration error
Result: Status Code 0
```

**Common Causes:**

- Upstream cluster not configured
- Route configuration error
- Service name resolution failure
- Envoy internal error

**Error Pattern:**

```
Error: "no healthy upstream"
Error: "cluster not found"
```

---

## 📊 **How to Diagnose Status Code 0**

### **1. Check Frontend Service Status**

```bash
kubectl get pod -n otel-demo -l app.kubernetes.io/component=frontend
kubectl logs -n otel-demo -l app.kubernetes.io/component=frontend --tail=50
```

**Look for:**

- Pod status (Running, CrashLoopBackOff, etc.)
- Recent restarts
- Error messages in logs

---

### **2. Check Envoy Logs**

```bash
kubectl logs -n otel-demo deployment/frontend-proxy -c frontend-proxy --tail=100 | grep -i "error\|refused\|timeout\|connection"
```

**Look for:**

- Connection refused errors
- Timeout messages
- Upstream connection errors
- Cluster configuration issues

---

### **3. Check Envoy Admin Stats**

```bash
kubectl exec -n otel-demo deployment/frontend-proxy -c frontend-proxy -- \
  wget -qO- http://localhost:10000/stats | grep -i "upstream\|cluster\|connection"
```

**Look for:**

- `upstream_cx_connect_fail` (connection failures)
- `upstream_cx_connect_timeout` (timeouts)
- `cluster.frontend.*` (upstream cluster stats)

---

### **4. Honeycomb Query for Status Code 0**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 0
VISUALIZE COUNT
GROUP BY time(1m)
```

**Then drill into traces:**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 0
VISUALIZE TRACES
LIMIT 10
```

**Look for:**

- Error messages in span attributes
- Duration (timeout = long duration, refused = short)
- Child spans (none = connection never established)

---

## 🔬 **Common Scenarios**

### **Scenario 1: Frontend Service Down**

**Symptoms:**

- Status code 0
- Error: "connection refused"
- Duration: < 10ms (fast failure)
- No child spans to frontend

**Fix:**

```bash
kubectl get pod -n otel-demo -l app.kubernetes.io/component=frontend
kubectl describe pod <frontend-pod> -n otel-demo
kubectl logs <frontend-pod> -n otel-demo
```

---

### **Scenario 2: Frontend Overloaded**

**Symptoms:**

- Status code 0
- Error: "timeout" or "context deadline exceeded"
- Duration: Matches Envoy timeout (often 15-30s)
- Some requests succeed, some fail

**Fix:**

- Check frontend resource usage
- Increase Envoy timeout
- Scale frontend service
- Check for deadlocks/blocking operations

---

### **Scenario 3: Network Policy Blocking**

**Symptoms:**

- Status code 0
- Error: "network unreachable" or "no route to host"
- Consistent failures (not intermittent)
- Other services work fine

**Fix:**

```bash
kubectl get networkpolicies -n otel-demo
kubectl describe networkpolicy <policy-name> -n otel-demo
```

---

### **Scenario 4: Service Discovery Failure**

**Symptoms:**

- Status code 0
- Error: "no such host" or DNS lookup failure
- Intermittent (DNS cache expires)
- Other services also affected

**Fix:**

```bash
kubectl get svc -n otel-demo frontend
kubectl get endpoints -n otel-demo frontend
kubectl exec -n otel-demo deployment/frontend-proxy -c frontend-proxy -- \
  nslookup frontend.otel-demo.svc.cluster.local
```

---

## 📈 **Honeycomb Queries for Investigation**

### **1. Count Status Code 0 Errors**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 0
VISUALIZE COUNT
GROUP BY time(1m)
```

---

### **2. Compare Status Code 0 vs Other Errors**

```
WHERE service.name = "frontend-proxy"
CALCULATE status_0 = COUNT_IF(http.status_code = 0)
CALCULATE status_500 = COUNT_IF(http.status_code = 500)
CALCULATE status_503 = COUNT_IF(http.status_code = 503)
VISUALIZE status_0, status_500, status_503
GROUP BY time(1m)
```

---

### **3. Status Code 0 by Endpoint**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 0
VISUALIZE COUNT
GROUP BY http.target
ORDER BY COUNT DESC
```

---

### **4. Status Code 0 Error Messages**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 0
VISUALIZE COUNT
GROUP BY error.message
ORDER BY COUNT DESC
```

---

### **5. Status Code 0 Duration Analysis**

```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 0
VISUALIZE P50(duration_ms), P95(duration_ms), P99(duration_ms)
GROUP BY time(1m)
```

**Interpretation:**

- **Short duration (< 10ms):** Connection refused (service down)
- **Long duration (15-30s):** Timeout (service overloaded)
- **Variable duration:** Network issues or client aborts

---

## ✅ **Quick Diagnostic Checklist**

When you see status code 0:

1. ✅ **Check frontend service is running**

   ```bash
   kubectl get pod -n otel-demo -l app.kubernetes.io/component=frontend
   ```

2. ✅ **Check Envoy can resolve frontend service**

   ```bash
   kubectl exec -n otel-demo deployment/frontend-proxy -c frontend-proxy -- \
     nslookup frontend.otel-demo.svc.cluster.local
   ```

3. ✅ **Check Envoy logs for errors**

   ```bash
   kubectl logs -n otel-demo deployment/frontend-proxy -c frontend-proxy --tail=100
   ```

4. ✅ **Check frontend logs for issues**

   ```bash
   kubectl logs -n otel-demo -l app.kubernetes.io/component=frontend --tail=100
   ```

5. ✅ **Check network policies**

   ```bash
   kubectl get networkpolicies -n otel-demo
   ```

6. ✅ **Check Envoy admin stats**
   ```bash
   kubectl port-forward -n otel-demo deployment/frontend-proxy 10000:10000
   # Open http://localhost:10000/stats
   ```

---

## 🎓 **Key Takeaways**

**Status Code 0 = No HTTP Response Received**

**Common Causes:**

1. **Connection refused** → Service down
2. **Timeout** → Service overloaded
3. **Network error** → Network/firewall issue
4. **Client abort** → Client canceled request
5. **Config error** → Envoy misconfiguration

**Diagnosis:**

- Check error messages in traces
- Check duration (short = refused, long = timeout)
- Check child spans (none = connection never established)
- Check service status and logs

**Status Code 0 is ALWAYS an error** - it means the request completely failed before any response.

---

**Last Updated:** November 9, 2025  
**Related:** `why-429-not-error.md` (429 is not an error, but 0 IS an error)
