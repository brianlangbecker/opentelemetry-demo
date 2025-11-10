# Application Crash Observability - What You Can See

**Purpose:** Understand all the observability capabilities when an application crashes (pod kill, JVM kill, OOM, etc.)

---

## 🎯 **What Happens When an Application Crashes**

### Crash Methods

1. **Manual Pod Kill:** `kubectl delete pod <pod-name>`
2. **JVM/Process Kill:** `kubectl exec <pod> -- killall <process>`
3. **OOM Kill:** Memory limit exceeded → Linux kernel kills process
4. **Graceful Shutdown:** Application receives SIGTERM and exits cleanly
5. **CrashLoopBackOff:** Repeated crashes → Kubernetes backs off restarts

---

## 📊 **Observability Capabilities**

### 1. **Kubernetes Events** (k8s-events dataset)

**What you can see:**

- **Pod lifecycle events:**
  - `Killing` - Pod termination initiated
  - `Created` - New pod created after crash
  - `Started` - Container started
  - `Unhealthy` - Readiness probe failures during recovery
  - `BackOff` - CrashLoopBackOff state

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.pod.name = "<pod-name>"
  AND k8s.event.reason IN ("Killing", "Started", "Created", "Unhealthy", "BackOff")
ORDER BY timestamp DESC
```

**What this shows:**
- Exact crash timestamp
- Recovery timeline
- Restart attempts
- Health check failures

---

### 2. **Container Termination Details** (k8s-events dataset)

**What you can see:**

- **Termination reason:**
  - `OOMKilled` - Out of memory
  - `Error` - Application error/crash
  - `Completed` - Graceful shutdown
  - `ContainerCannotRun` - Configuration issue

- **Exit code:**
  - `137` - OOM kill (128 + 9 SIGKILL)
  - `1` - General error
  - `0` - Success (graceful shutdown)

- **Termination message:**
  - Last log output before crash
  - Error messages
  - Stack traces

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.pod.name = "<pod-name>"
  AND k8s.container.last_terminated.reason EXISTS
VISUALIZE k8s.container.last_terminated.reason, 
         k8s.container.last_terminated.exit_code,
         k8s.container.last_terminated.message
ORDER BY timestamp DESC
```

**What this shows:**
- Why the container crashed
- Exit code (distinguishes OOM vs error)
- Last known state before crash

---

### 3. **Restart Count Metrics** (opentelemetry-demo dataset)

**What you can see:**

- **Container restart count:** `k8s.container.restart_count`
- **Restart rate:** How frequently crashes occur
- **Recovery pattern:** Does service stabilize or keep crashing?

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY time(30s)
```

**What this shows:**
- Increments each time container restarts
- Pattern: Single crash vs CrashLoopBackOff
- Recovery: Does restart count stabilize?

---

### 4. **Pod Phase Changes** (k8s-events dataset)

**What you can see:**

- **Pod phases:**
  - `Running` → `Pending` (crash)
  - `Pending` → `Running` (recovery)
  - `Failed` (if restart policy exhausted)

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.pod.name = "<pod-name>"
VISUALIZE k8s.pod.phase
GROUP BY time(10s)
```

**What this shows:**
- Pod lifecycle during crash/recovery
- Time spent in each phase
- Recovery duration

---

### 5. **Trace Analysis** (opentelemetry-demo dataset)

**What you can see:**

- **Abrupt trace endings:**
  - Traces that end mid-operation
  - No completion spans
  - Missing child spans

- **Error correlation:**
  - Last successful operation before crash
  - What was happening when crash occurred
  - Link to fatal log entries

**Query:**
```
WHERE service.name = "checkout"
  AND otel.status_code = ERROR
VISUALIZE TRACES
ORDER BY timestamp DESC
LIMIT 20
```

**What to look for:**
- Traces ending abruptly (no completion)
- Last span before crash
- Error messages in final span
- Duration pattern (sudden cutoff)

---

### 6. **Service Availability Metrics**

**What you can see:**

- **Request rate drop:**
  - Service stops receiving requests
  - Traffic shifts to other instances (if multiple replicas)
  - Zero requests during downtime

**Query:**
```
WHERE service.name = "checkout"
VISUALIZE COUNT
GROUP BY time(10s)
```

**What this shows:**
- Request rate drops to 0 during crash
- Recovery: Request rate returns
- Downtime duration

---

### 7. **Error Rate Spikes** (Downstream Services)

**What you can see:**

- **Cascading failures:**
  - Services calling crashed service get errors
  - Connection refused errors
  - Timeout errors

**Query:**
```
WHERE service.name = "frontend"
  AND error = true
  AND (error.message CONTAINS "connection refused" 
       OR error.message CONTAINS "no such host")
VISUALIZE COUNT
GROUP BY time(10s)
```

**What this shows:**
- Impact on dependent services
- Error propagation
- User-facing impact

---

### 8. **Memory/Resource Metrics** (Before Crash)

**What you can see:**

- **Pre-crash metrics:**
  - Memory spike before OOM
  - CPU spike before crash
  - Resource exhaustion pattern

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.pod.memory.working_set),
         MAX(k8s.pod.cpu_utilization)
GROUP BY time(10s)
```

**What this shows:**
- Resource usage leading to crash
- Predictable failure pattern
- Early warning indicators

---

### 9. **MTTR (Mean Time To Recovery) Calculation**

**What you can see:**

- **Recovery time metrics:**
  - Time from crash to pod restart
  - Time from restart to ready
  - Total downtime duration

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.pod.name = "<pod-name>"
  AND k8s.event.reason = "Killing"
VISUALIZE timestamp AS "crash_time"
```

Then query for recovery:
```
WHERE namespace = "otel-demo"
  AND k8s.pod.name = "<pod-name>"
  AND k8s.event.reason = "Started"
VISUALIZE timestamp AS "recovery_time"
```

**Calculate MTTR:**
- `recovery_time - crash_time = downtime`
- Average across multiple crashes = MTTR

---

### 10. **Log Correlation** (Fatal Log Entries)

**What you can see:**

- **Last log entries before crash:**
  - Fatal errors
  - Stack traces
  - Panic messages
  - Out of memory warnings

**Query:**
```
WHERE service.name = "checkout"
  AND log.level = "fatal" OR log.level = "error"
VISUALIZE log.message
ORDER BY timestamp DESC
LIMIT 50
```

**What this shows:**
- Root cause of crash
- Error context
- Link to trace that crashed

---

## 🚨 **Alert Configuration**

### Alert 1: Pod Restart Detected

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.event.reason = "Killing"
  AND k8s.container.last_terminated.reason = "OOMKilled"
VISUALIZE COUNT
GROUP BY k8s.pod.name, time(5m)
```

**Trigger:**
- COUNT > 0 (any OOM kill)
- Frequency: Every 1 minute
- Severity: CRITICAL

**Message:**
```
🔴 Pod OOM Kill Detected

Pod: {{k8s.pod.name}}
Reason: {{k8s.container.last_terminated.reason}}
Exit Code: {{k8s.container.last_terminated.exit_code}}

Action: Check memory limits and usage patterns
```

---

### Alert 2: CrashLoopBackOff

**Query:**
```
WHERE namespace = "otel-demo"
  AND k8s.event.reason = "BackOff"
  AND k8s.container.restart_count > 5
VISUALIZE COUNT
GROUP BY k8s.pod.name, time(5m)
```

**Trigger:**
- COUNT > 0
- Frequency: Every 1 minute
- Severity: CRITICAL

**Message:**
```
🔴 CrashLoopBackOff Detected

Pod: {{k8s.pod.name}}
Restart Count: {{k8s.container.restart_count}}
Last Exit Code: {{k8s.container.last_terminated.exit_code}}

Action: Service cannot recover - investigate root cause
```

---

### Alert 3: Service Down (No Requests)

**Query:**
```
WHERE service.name = "checkout"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Trigger:**
- COUNT = 0 for 2 minutes
- Frequency: Every 1 minute
- Severity: CRITICAL

**Message:**
```
🔴 Service Down

Service: checkout
No requests received for 2+ minutes

Action: Check pod status and restart events
```

---

### Alert 4: High Restart Rate

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY time(10m)
```

**Trigger:**
- Increase > 3 restarts in 10 minutes
- Frequency: Every 5 minutes
- Severity: WARNING

**Message:**
```
⚠️ High Restart Rate

Pod: {{k8s.pod.name}}
Restarts: {{MAX(k8s.container.restart_count)}}

Action: Service unstable - investigate crash pattern
```

---

## 📈 **Dashboard Panels**

### Panel 1: Crash Timeline
```
WHERE namespace = "otel-demo"
  AND k8s.pod.name = "<pod-name>"
VISUALIZE k8s.event.reason
BREAKDOWN k8s.event.reason
GROUP BY time(30s)
```

### Panel 2: Restart Count Over Time
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY time(1m)
```

### Panel 3: Termination Reasons
```
WHERE namespace = "otel-demo"
  AND k8s.container.last_terminated.reason EXISTS
VISUALIZE COUNT
BREAKDOWN k8s.container.last_terminated.reason
```

### Panel 4: Service Availability
```
WHERE service.name = "checkout"
VISUALIZE COUNT
GROUP BY time(10s)
```

### Panel 5: Pre-Crash Memory
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(10s)
```

### Panel 6: Cascading Errors
```
WHERE service.name = "frontend"
  AND error = true
  AND error.message CONTAINS "connection refused"
VISUALIZE COUNT
GROUP BY time(30s)
```

---

## 🎓 **Key Takeaways**

### What You CAN Observe:

✅ **Exact crash timestamp** (Kubernetes events)  
✅ **Crash reason** (OOMKilled, Error, etc.)  
✅ **Exit code** (137 = OOM, 1 = error)  
✅ **Restart count** (single crash vs CrashLoopBackOff)  
✅ **Recovery timeline** (pod phases, restart duration)  
✅ **Pre-crash metrics** (memory/CPU before crash)  
✅ **Trace correlation** (what was happening when crash occurred)  
✅ **Cascading failures** (downstream service errors)  
✅ **MTTR calculation** (downtime duration)  
✅ **Fatal log entries** (root cause analysis)  

### What You CANNOT Directly Observe:

❌ **In-flight request loss** (requests in progress when crash occurs)  
❌ **Graceful shutdown duration** (SIGTERM handling time)  
❌ **Process-level details** (thread dumps, heap dumps) - requires additional tooling  
❌ **Network partition impact** (if crash is network-related)  

---

## 🔧 **How to Trigger Crashes for Testing**

### Method 1: Manual Pod Kill
```bash
kubectl delete pod <pod-name> -n otel-demo
```

### Method 2: Kill Process Inside Pod
```bash
kubectl exec <pod-name> -n otel-demo -- killall <process-name>
```

### Method 3: OOM Kill (Memory Limit)
```bash
# Reduce memory limit
kubectl set resources deployment checkout -n otel-demo --limits=memory=10Mi

# Generate load to exceed limit
# See: memory-tracking-spike-crash.md
```

### Method 4: Feature Flag (if available)
- `adFailure: on` - Ad service crash
- `cartFailure: on` - Cart service crash
- `paymentUnreachable: on` - Payment service crash

---

## 📚 **Related Scenarios**

- **[Memory Spike Crash](memory-tracking-spike-crash.md)** - OOM kill demonstration
- **[Gradual Memory Leak](memory-leak-gradual-checkout.md)** - Predictable crash pattern
- **[JVM GC Thrashing](jvm-gc-thrashing-ad-service.md)** - Zombie service (crashes but restarts)
- **[Istiod Crash/Restart](istiod-crash-restart.md)** - Control plane crash example

---

**Last Updated:** December 2024  
**Status:** Observability capabilities documented - ready for testing

