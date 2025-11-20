# Pod Restart Alerts - Honeycomb Configuration

**Purpose:** Create alerts to detect and notify when pods restart/crash in Kubernetes.

---

## Alert Types for Pod Restarts

### Alert 1: Restart Count Increase (Most Reliable)

**Type:** Metric-based alert on restart count increment

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY k8s.pod.name, time(1m)
```

**Alert Configuration:**
- **Trigger:** `INCREASE(MAX(k8s.container.restart_count)) > 0`
- **Frequency:** Every 1 minute
- **Alert Type:** `on_true` (fires when condition is true)
- **Severity:** WARNING (for single restart) or CRITICAL (for multiple)
- **Duration:** For at least 1 minute

**Message:**
```
⚠️ Pod Restart Detected

Pod: {{k8s.pod.name}}
Service: {{service_name_from_pod}}
Restart Count: {{MAX(k8s.container.restart_count)}}
Previous Count: {{MAX(k8s.container.restart_count) - 1}}

Action: Check logs and resource usage
```

**Why this works:**
- `INCREASE()` detects when restart_count goes up
- Works even if pod name changes (filters by service name pattern)
- Most reliable method

---

### Alert 2: OOM Kill Detection (Critical)

**Type:** Event-based alert on OOMKilled reason

**Query:**
```
DATASET: k8s-events
WHERE namespace = "otel-demo"
  AND k8s.container.last_terminated.reason = "OOMKilled"
VISUALIZE COUNT
BREAKDOWN k8s.pod.name, k8s.container.name
TIME RANGE: Last 5 minutes
```

**Alert Configuration:**
- **Trigger:** `COUNT > 0`
- **Frequency:** Every 1 minute
- **Alert Type:** `on_true`
- **Severity:** CRITICAL
- **Duration:** For at least 1 minute

**Message:**
```
🔴 Pod OOM Kill Detected

Pod: {{k8s.pod.name}}
Container: {{k8s.container.name}}
Reason: OOMKilled
Exit Code: 137

Action: 
- Check memory limits
- Review memory usage patterns
- Consider increasing memory limit
```

**Why this works:**
- Detects specific crash reason (OOM)
- Provides actionable information
- Critical severity for resource exhaustion

---

### Alert 3: CrashLoopBackOff Detection

**Type:** Event-based alert on BackOff event

**Query:**
```
DATASET: k8s-events
WHERE namespace = "otel-demo"
  AND k8s.event.reason = "BackOff"
  AND k8s.container.restart_count > 3
VISUALIZE COUNT
BREAKDOWN k8s.pod.name
TIME RANGE: Last 5 minutes
```

**Alert Configuration:**
- **Trigger:** `COUNT > 0`
- **Frequency:** Every 1 minute
- **Alert Type:** `on_true`
- **Severity:** CRITICAL
- **Duration:** For at least 2 minutes

**Message:**
```
🔴 CrashLoopBackOff Detected

Pod: {{k8s.pod.name}}
Service: {{service_name_from_pod}}
Restart Count: {{MAX(k8s.container.restart_count)}}
Status: Pod cannot recover

Action: 
- Service is in crash loop
- Check application logs
- Review startup configuration
- May need to fix application code
```

**Why this works:**
- Detects when pod cannot recover
- Indicates persistent failure
- Requires immediate attention

---

### Alert 4: High Restart Rate (Multiple Restarts)

**Type:** Metric-based alert on rapid restarts

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY k8s.pod.name, time(5m)
```

**Alert Configuration:**
- **Trigger:** `INCREASE(MAX(k8s.container.restart_count)) >= 3` (3+ restarts in 5 minutes)
- **Frequency:** Every 1 minute
- **Alert Type:** `on_true`
- **Severity:** CRITICAL
- **Duration:** For at least 2 minutes

**Message:**
```
🔴 High Restart Rate

Pod: {{k8s.pod.name}}
Service: {{service_name_from_pod}}
Restarts in 5min: {{INCREASE(MAX(k8s.container.restart_count))}}
Total Restarts: {{MAX(k8s.container.restart_count)}}

Action: 
- Pod is restarting frequently
- Check for resource exhaustion
- Review application health checks
- May indicate configuration issue
```

**Why this works:**
- Catches rapid restart patterns
- Distinguishes single crash from persistent issue
- Helps identify unstable services

---

### Alert 5: Service Unavailable (No Traffic After Restart)

**Type:** Trace-based alert on service downtime

**Query:**
```
WHERE service.name = "checkout"
VISUALIZE COUNT
GROUP BY time(1m)
```

**Alert Configuration:**
- **Trigger:** `COUNT = 0` (no requests for 2+ minutes)
- **Frequency:** Every 1 minute
- **Alert Type:** `on_true`
- **Severity:** CRITICAL
- **Duration:** For at least 2 minutes

**Message:**
```
🔴 Service Down

Service: checkout
No requests received for 2+ minutes

Action: 
- Service may have crashed
- Check pod status: kubectl get pod -n otel-demo | grep checkout
- Check restart events
- Verify service is running
```

**Why this works:**
- Detects service unavailability
- Complements restart alerts
- Indicates user impact

---

### Alert 6: Pod Killing Event (Pre-Crash Warning)

**Type:** Event-based alert on Killing event

**Query:**
```
DATASET: k8s-events
WHERE namespace = "otel-demo"
  AND k8s.event.reason = "Killing"
VISUALIZE COUNT
BREAKDOWN k8s.pod.name
TIME RANGE: Last 5 minutes
```

**Alert Configuration:**
- **Trigger:** `COUNT > 0`
- **Frequency:** Every 1 minute
- **Alert Type:** `on_true`
- **Severity:** WARNING
- **Duration:** For at least 1 minute

**Message:**
```
⚠️ Pod Being Terminated

Pod: {{k8s.pod.name}}
Service: {{service_name_from_pod}}
Event: Killing

Action: 
- Pod is about to restart
- Check why (OOM, health check failure, etc.)
- Monitor for recovery
```

**Why this works:**
- Early warning before restart
- Can catch issues before they become critical
- Useful for proactive monitoring

---

## Recommended Alert Setup

### For Production: Use Multiple Alerts

**Tier 1: Critical Alerts (Immediate Action)**
1. **OOM Kill Alert** - Resource exhaustion
2. **CrashLoopBackOff Alert** - Service cannot recover
3. **Service Down Alert** - No traffic

**Tier 2: Warning Alerts (Monitor)**
4. **Restart Count Increase** - Single restart
5. **Pod Killing Event** - Pre-crash warning

**Tier 3: Informational (Trend Analysis)**
6. **High Restart Rate** - Pattern detection

---

## Alert Query Templates

### Template 1: Any Restart (Generic)

```
WHERE k8s.pod.name EXISTS
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY k8s.pod.name, time(1m)
```

**Trigger:** `INCREASE(MAX(k8s.container.restart_count)) > 0`

### Template 2: Service-Specific Restart

```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY k8s.pod.name, time(1m)
```

**Trigger:** `INCREASE(MAX(k8s.container.restart_count)) > 0`

### Template 3: All Services (Using Derived Column)

```
WHERE service_name_from_pod EXISTS
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY service_name_from_pod, time(1m)
```

**Trigger:** `INCREASE(MAX(k8s.container.restart_count)) > 0`

---

## Using Derived Column for Service Name

If you've created the `service_name_from_pod` derived column, you can filter by service:

```
WHERE service_name_from_pod = "checkout"
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY k8s.pod.name, time(1m)
```

**Benefits:**
- Works even if pod name changes
- Groups by service, not individual pods
- Easier to manage alerts per service

---

## Alert Best Practices

### 1. Use INCREASE() for Restart Count

**✅ Good:**
```
INCREASE(MAX(k8s.container.restart_count)) > 0
```

**❌ Bad:**
```
MAX(k8s.container.restart_count) > 0
```
(Triggers continuously, not just on restart)

### 2. Set Appropriate Duration

- **Single restart:** 1 minute duration
- **CrashLoopBackOff:** 2-5 minutes duration
- **Service down:** 2 minutes duration

### 3. Use Breakdown for Context

```
BREAKDOWN k8s.pod.name, service_name_from_pod
```

Provides pod name and service in alert message.

### 4. Combine with Other Metrics

**Alert on restart + high memory:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
  AND INCREASE(MAX(k8s.container.restart_count)) > 0
  AND MAX(memory_usage_percent) > 90
VISUALIZE COUNT
```

**Alert on restart + error rate:**
```
WHERE service.name = "checkout"
  AND INCREASE(MAX(k8s.container.restart_count)) > 0
  AND error_rate > 0.1
VISUALIZE COUNT
```

---

## Quick Setup: Copy-Paste Alerts

### Alert 1: Any Pod Restart (All Services)

**Query:**
```
WHERE k8s.pod.name EXISTS
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY k8s.pod.name, time(1m)
```

**Trigger:** `INCREASE(MAX(k8s.container.restart_count)) > 0`  
**Severity:** WARNING  
**Frequency:** 1 minute

### Alert 2: Checkout Service Restart

**Query:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE INCREASE(MAX(k8s.container.restart_count))
GROUP BY k8s.pod.name, time(1m)
```

**Trigger:** `INCREASE(MAX(k8s.container.restart_count)) > 0`  
**Severity:** WARNING  
**Frequency:** 1 minute

### Alert 3: OOM Kill (Critical)

**Query:**
```
DATASET: k8s-events
WHERE namespace = "otel-demo"
  AND k8s.container.last_terminated.reason = "OOMKilled"
VISUALIZE COUNT
BREAKDOWN k8s.pod.name
TIME RANGE: Last 5 minutes
```

**Trigger:** `COUNT > 0`  
**Severity:** CRITICAL  
**Frequency:** 1 minute

---

## Testing Your Alerts

### Trigger a Test Restart

```bash
# Delete a pod to trigger restart
kubectl delete pod -n otel-demo -l app.kubernetes.io/name=checkout

# Watch for alert
# Should fire within 1-2 minutes
```

### Verify Alert Fires

1. Go to Honeycomb → Alerts
2. Check alert history
3. Verify alert fired for the restart
4. Check alert message contains pod name

---

## Troubleshooting

### Alert Not Firing

**Check if restart_count metric exists:**
```
WHERE k8s.container.restart_count EXISTS
VISUALIZE COUNT
```

**Check if events are being collected:**
```
DATASET: k8s-events
WHERE namespace = "otel-demo"
VISUALIZE COUNT
```

**Verify query works:**
```
WHERE k8s.pod.name STARTS_WITH "checkout"
VISUALIZE MAX(k8s.container.restart_count)
GROUP BY k8s.pod.name
```

### Alert Firing Too Often

**Increase duration:**
- Change from 1 minute to 2-5 minutes
- Prevents alert spam during rapid restarts

**Add threshold:**
- Only alert if `INCREASE() >= 2` (multiple restarts)
- Filters out single transient restarts

---

**Last Updated:** December 2024  
**Status:** Ready to use

