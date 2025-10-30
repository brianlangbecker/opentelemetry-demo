# Kubernetes Events in Honeycomb - Complete Guide

This guide explains how Kubernetes events (including OOMKilled, crashes, and restarts) are captured and queried in Honeycomb.

---

## 📊 Overview

The OpenTelemetry Collector's `k8sobjects` receiver watches Kubernetes pods and events, extracting container status information (including crash reasons like OOMKilled) and sending them to Honeycomb's `k8s-events` dataset.

---

## 🔧 Configuration

The `transform/k8s_events` processor extracts container status fields from Kubernetes Pod objects:

### **What's Captured:**

| **Source** | **Fields Extracted** |
|-----------|---------------------|
| **Events** | `Started`, `BackOff`, `Scheduled`, `Pulled`, etc. |
| **Pod Status** | Container states, restart counts, termination reasons |
| **Container Crashes** | `OOMKilled`, exit codes, error messages |

### **Key Configuration:**

```yaml
k8sobjects:
  auth_type: serviceAccount
  objects:
    - name: pods
      mode: watch
      exclude_watch_type:
        - DELETED
    - name: events
      mode: watch
      group: events.k8s.io
      namespaces: [otel-demo]

transform/k8s_events:
  log_statements:
    - context: log
      statements:
        # Extract Pod crash info (OOMKilled, etc.)
        - set(attributes["k8s.container.last_terminated.reason"], ...)
        - set(attributes["k8s.container.last_terminated.exit_code"], ...)
        - set(attributes["k8s.container.restart_count"], ...)
```

**Full config:** See `infra/otel-demo-values.yaml` lines 99-130

---

## 📋 Available Fields in Honeycomb

### **Pod Identification:**
- `k8s.pod.name` - Pod name
- `k8s.namespace.name` - Namespace
- `k8s.pod.phase` - `Running`, `Failed`, `Pending`, etc.

### **Container Status:**
- `k8s.container.name` - Container name
- `k8s.container.restart_count` - Number of restarts
- `k8s.container.ready` - `true` or `false`
- `k8s.container.state` - `Running`, `CrashLoopBackOff`, `Terminated`, etc.

### **Crash Information (The Good Stuff!):**
- `k8s.container.last_terminated.reason` - **`OOMKilled`**, `Error`, `ContainerCannotRun`, etc.
- `k8s.container.last_terminated.exit_code` - `137` (OOM), `1` (error), etc.
- `k8s.container.last_terminated.message` - Detailed error message
- `k8s.container.last_terminated.finished_at` - When the crash happened

### **Event Information:**
- `k8s.event.reason` - `Started`, `BackOff`, `Scheduled`, etc.
- `k8s.event.type` - `Normal` or `Warning`
- `k8s.event.message` - Event description

### **Object Type:**
- `k8s.object.kind` - `Pod` or `Event` (use to distinguish data sources)

---

## 🎯 Essential Honeycomb Queries

### **1. Find All OOMKilled Events**

```
DATASET: k8s-events
WHERE: k8s.container.last_terminated.reason = 'OOMKilled'
TIME RANGE: Last 24 hours
VISUALIZE: COUNT()
GROUP BY: k8s.pod.name, k8s.container.name, time(1h)
ORDER BY: COUNT() DESC
```

**Use Case:** See which pods ran out of memory and when

---

### **2. All Container Crashes (Any Reason)**

```
DATASET: k8s-events
WHERE: 
  k8s.container.last_terminated.reason EXISTS
  AND k8s.container.last_terminated.reason != ''
TIME RANGE: Last 24 hours
VISUALIZE: COUNT()
GROUP BY: k8s.container.last_terminated.reason, k8s.pod.name
```

**Shows:**
- `OOMKilled` - Out of memory
- `Error` - Generic errors
- `ContainerCannotRun` - Failed to start
- `StartError` - Startup failures

---

### **3. Exit Codes (Debugging Crashes)**

```
DATASET: k8s-events
WHERE: k8s.container.last_terminated.exit_code > 0
TIME RANGE: Last 24 hours
VISUALIZE: COUNT()
GROUP BY: 
  k8s.container.last_terminated.exit_code,
  k8s.container.last_terminated.reason,
  k8s.pod.name
```

**Common Exit Codes:**
- `137` = OOMKilled (SIGKILL from OOM killer)
- `143` = Graceful termination (SIGTERM)
- `1` = General application error
- `255` = Exit status out of range

---

### **4. Pods with High Restart Counts**

```
DATASET: k8s-events
WHERE:
  k8s.object.kind = 'Pod'
  AND k8s.container.restart_count > 0
TIME RANGE: Last 1 hour
VISUALIZE: MAX(k8s.container.restart_count)
GROUP BY: k8s.pod.name, k8s.container.name
ORDER BY: MAX(k8s.container.restart_count) DESC
```

**Use Case:** Find unstable pods that are restarting frequently

---

### **5. Current Container States (Health Check)**

```
DATASET: k8s-events
WHERE: k8s.object.kind = 'Pod'
TIME RANGE: Last 15 minutes
VISUALIZE: LATEST(k8s.container.state)
GROUP BY: k8s.pod.name, k8s.container.name
FILTER: k8s.container.state != 'Running'
```

**Unhealthy States:**
- `CrashLoopBackOff` - Container keeps crashing
- `ImagePullBackOff` - Can't pull container image
- `Error` - Container in error state
- `Terminating` - Being shut down

---

### **6. Pod Lifecycle Events**

```
DATASET: k8s-events
WHERE:
  k8s.object.kind = 'Event'
  AND k8s.event.type = 'Warning'
TIME RANGE: Last 30 minutes
VISUALIZE: COUNT()
GROUP BY: k8s.event.reason, k8s.pod.name
```

**Warning Events:**
- `BackOff` - Crash loop detected
- `FailedScheduling` - Can't schedule pod
- `Unhealthy` - Health probe failed
- `Evicted` - Pod evicted due to resource pressure

---

### **7. PostgreSQL Specific Monitoring**

```
DATASET: k8s-events
WHERE:
  k8s.pod.name CONTAINS 'postgresql'
  AND (
    k8s.container.last_terminated.reason EXISTS OR
    k8s.event.type = 'Warning' OR
    k8s.container.restart_count > 0
  )
TIME RANGE: Last 24 hours
VISUALIZE: COUNT()
GROUP BY: 
  k8s.container.last_terminated.reason,
  k8s.event.reason,
  time(1h)
```

**Perfect for:** Chaos engineering scenarios and production monitoring

---

## 🚨 Recommended Alerts

### **Alert 1: OOMKilled Alert**

```
Name: Pod OOMKilled
Dataset: k8s-events
WHERE: k8s.container.last_terminated.reason = 'OOMKilled'
TRIGGER: COUNT() >= 1 in last 5 minutes
FREQUENCY: Immediate
MESSAGE: "🚨 Pod {{ k8s.pod.name }} container {{ k8s.container.name }} was OOMKilled!"
```

**Action:** Increase memory limits for affected pod

---

### **Alert 2: Crash Loop Detected**

```
Name: Pod in CrashLoopBackOff
Dataset: k8s-events
WHERE: k8s.container.state = 'CrashLoopBackOff'
TRIGGER: COUNT() >= 1 in last 5 minutes
FREQUENCY: Immediate
MESSAGE: "🔄 Pod {{ k8s.pod.name }} is in crash loop!"
```

**Action:** Check pod logs for startup errors

---

### **Alert 3: High Restart Rate**

```
Name: Frequent Pod Restarts
Dataset: k8s-events
WHERE: k8s.container.restart_count > 3
TRIGGER: MAX(k8s.container.restart_count) >= 3 in last 10 minutes
FREQUENCY: Every 10 minutes
MESSAGE: "⚠️ Pod {{ k8s.pod.name }} has restarted {{ MAX(k8s.container.restart_count) }} times!"
```

**Action:** Investigate pod stability and resource allocation

---

### **Alert 4: Multiple Crashes**

```
Name: Multiple Pods Crashing
Dataset: k8s-events
WHERE: k8s.container.last_terminated.reason EXISTS
TRIGGER: COUNT() >= 3 in last 15 minutes
FREQUENCY: Every 15 minutes
MESSAGE: "🔥 {{ COUNT() }} containers crashed in last 15 minutes!"
```

**Action:** Check for cluster-wide issues (node failures, network problems)

---

## 📊 Pre-Built Dashboard

Create a Honeycomb board with these panels:

### **Panel 1: OOMKilled Timeline**
```
WHERE: k8s.container.last_terminated.reason = 'OOMKilled'
VISUALIZE: COUNT()
GROUP BY: time(10m)
GRAPH: Line chart
```

### **Panel 2: Crash Breakdown**
```
WHERE: k8s.container.last_terminated.reason EXISTS
VISUALIZE: COUNT()
GROUP BY: k8s.container.last_terminated.reason
GRAPH: Pie chart
```

### **Panel 3: Top Unstable Pods**
```
WHERE: k8s.container.restart_count > 0
VISUALIZE: MAX(k8s.container.restart_count)
GROUP BY: k8s.pod.name
ORDER BY: MAX(k8s.container.restart_count) DESC
LIMIT: 10
GRAPH: Bar chart
```

### **Panel 4: Current Pod States**
```
WHERE: k8s.object.kind = 'Pod'
VISUALIZE: LATEST(k8s.container.state)
GROUP BY: k8s.pod.name
FILTER: k8s.container.state != 'Running'
GRAPH: Table
```

---

## 🔍 Troubleshooting

### **Problem: No OOMKilled events showing up**

**Check 1: Are you querying the right dataset?**
```
Dataset must be: k8s-events (NOT opentelemetry-demo)
```

**Check 2: Are Pod objects being captured?**
```
DATASET: k8s-events
WHERE: k8s.object.kind = 'Pod'
TIME RANGE: Last 15 minutes
VISUALIZE: COUNT()
```
Expected: Should see Pod events

**Check 3: Is the transform processor working?**
```
DATASET: k8s-events
WHERE: k8s.container.last_terminated.reason EXISTS
VISUALIZE: COUNT()
```
Expected: Should see events with this field populated

---

### **Problem: Seeing DELETED events instead of real-time events**

**Issue:** The `body.type = 'DELETED'` field indicates Kubernetes Event objects being deleted after TTL (1 hour)

**Solution:** Filter them out:
```
WHERE: 
  body.type != 'DELETED'  ← Exclude deleted events
  OR body.type NOT EXISTS  ← Include Pod objects (no body.type)
```

Or use the flattened fields instead:
```
WHERE: k8s.container.last_terminated.reason = 'OOMKilled'
```
This automatically excludes old deleted events!

---

### **Problem: Can't see crash details for pods from yesterday**

**Root Cause:** Kubernetes Events are only retained for ~1 hour in the K8s API

**Solutions:**
1. **Honeycomb retention:** Events ARE stored in Honeycomb long-term (query them!)
2. **Check Honeycomb timestamp:** Use the actual ingestion timestamp
3. **Use Pod objects:** Pod status is retained as long as pod exists

```
DATASET: k8s-events
WHERE: k8s.container.last_terminated.finished_at > '2025-10-29T00:00:00Z'
```

---

### **Problem: Multiple containers per pod (which one crashed?)**

**Issue:** The transform only extracts the **first container** (`containerStatuses[0]`)

**Current Limitation:** Multi-container pods only show first container's status

**Workaround:** Check the raw `body` field for all containers:
```
DATASET: k8s-events
WHERE: k8s.pod.name = 'grafana-xxxx'
BREAKDOWN BY: body.object.status.containerStatuses
```

**Future Enhancement:** Loop through all containers (requires more complex transform logic)

---

## 🎓 Understanding the Data

### **Two Data Sources:**

1. **Kubernetes Events** (`k8s.object.kind = 'Event'`)
   - Lifecycle events: `Started`, `Scheduled`, `Pulled`
   - Warnings: `BackOff`, `FailedScheduling`, `Unhealthy`
   - Short-lived (1 hour retention in K8s)

2. **Pod Status Updates** (`k8s.object.kind = 'Pod'`)
   - Container states and termination reasons
   - Restart counts
   - Continuously updated while pod exists
   - **This is where OOMKilled appears!**

---

### **Why OOMKilled is in Pod status, not Events:**

When a container is OOMKilled:
1. Kubernetes terminates the container
2. Sets `lastState.terminated.reason = 'OOMKilled'` in Pod status
3. May (or may not) create a separate Event object
4. Our transform extracts this from Pod status updates

**This is why we watch Pods, not just Events!**

---

### **Timestamp Confusion:**

| **Field** | **What It Means** |
|----------|------------------|
| Honeycomb `timestamp` | When Honeycomb ingested the event |
| `body.object.deprecatedFirstTimestamp` | When K8s Event was first created |
| `k8s.container.last_terminated.finished_at` | When container actually crashed |

**For OOMKilled queries:** Use `k8s.container.last_terminated.finished_at` for accuracy!

---

## 🔗 Related Documentation

- **Setup Guide:** `infra/README.md` - How to install and configure
- **Chaos Scenarios:** `chaos-scenarios/` - Trigger OOMKilled for testing
- **PostgreSQL Monitoring:** `chaos-scenarios/postgres-disk-iops-pressure.md`

---

## 📝 Summary

### **Quick Reference:**

```
Dataset: k8s-events

OOMKilled:          k8s.container.last_terminated.reason = 'OOMKilled'
All Crashes:        k8s.container.last_terminated.reason EXISTS
Exit Codes:         k8s.container.last_terminated.exit_code
Restart Count:      k8s.container.restart_count
Current State:      k8s.container.state
Pod Phase:          k8s.pod.phase

Filter Pod data:    k8s.object.kind = 'Pod'
Filter Event data:  k8s.object.kind = 'Event'
```

### **Most Important Fields:**

1. `k8s.container.last_terminated.reason` ← **OOMKilled shows up here**
2. `k8s.container.last_terminated.exit_code` ← `137` = OOM
3. `k8s.container.restart_count` ← Stability indicator
4. `k8s.event.reason` ← Lifecycle events

---

## 🎉 What You Can Now Do:

✅ **Detect OOMKilled** - Instantly see memory crashes  
✅ **Track Restarts** - Know which pods are unstable  
✅ **Monitor Exit Codes** - Understand failure modes  
✅ **Alert on Crashes** - Proactive incident response  
✅ **Analyze Patterns** - Timeline view of container health  
✅ **Chaos Testing** - Verify your monitoring works!  

**Your Kubernetes monitoring is now production-ready!** 🚀

