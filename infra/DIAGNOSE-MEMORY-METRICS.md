# Diagnosing Missing Memory Metrics for Checkout

**Problem:** `k8s.pod.memory.usage` (or similar) not showing data for checkout service.

---

## Quick Diagnostic Queries

### Query 1: Find All Memory Fields for Checkout

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE COUNT
BREAKDOWN *
LIMIT 200
```

**Then manually filter** the breakdown to find fields containing "memory":
- Look for: `k8s.pod.memory.*`
- Note which ones have values vs. null

### Query 2: Check What Memory Fields Actually Exist

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE
  MAX(k8s.pod.memory.working_set) AS "working_set",
  MAX(k8s.pod.memory.usage) AS "usage",
  MAX(k8s.pod.memory.available) AS "available",
  MAX(k8s.pod.memory.limit) AS "limit",
  MAX(k8s.pod.memory_limit_utilization) AS "limit_utilization"
GROUP BY k8s.pod.name
LIMIT 20
```

**What to look for:**
- Which fields have values (not null)?
- `working_set` is the most common metric from kubeletstats

### Query 3: Check All Metrics for Checkout Pod

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE COUNT
BREAKDOWN *
TIME RANGE: Last 15 minutes
```

**Filter results** to find:
- Fields starting with `k8s.pod.memory.`
- Fields starting with `k8s.container.memory.`
- Any other memory-related fields

---

## Common Issue: Wrong Field Name

**The kubeletstats receiver typically emits:**
- ✅ `k8s.pod.memory.working_set` (most common)
- ✅ `k8s.pod.memory.limit`
- ✅ `k8s.pod.memory_limit_utilization`
- ❌ `k8s.pod.memory.usage` (may not exist)

**Try this query instead:**
```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(30s)
TIME RANGE: Last 1 hour
```

---

## Verify kubeletstats Receiver is Working

### Check Collector Logs

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector --tail=100 | grep -i "kubeletstats\|memory"
```

**Look for:**
- No errors about kubeletstats
- Metrics being collected

### Check Collector Config

```bash
kubectl get configmap otel-collector -n otel-demo -o yaml | grep -A 10 "kubeletstats:"
```

**Should show:**
```yaml
kubeletstats:
  collection_interval: 20s
  auth_type: "serviceAccount"
  metric_groups:
    - pod
    - node
    - container
```

### Verify Metrics Pipeline

```bash
kubectl get configmap otel-collector -n otel-demo -o yaml | grep -A 5 "metrics:" | grep -A 5 "kubeletstats"
```

**Should show `kubeletstats` in the metrics pipeline receivers list.**

---

## Check if Metrics Are Being Collected at All

### Query: Any Metrics for Checkout Pod?

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**If this returns 0:**
- Metrics aren't being collected for checkout pod
- Check kubeletstats receiver configuration
- Check if pod has proper labels

### Query: Check All Pods Have Memory Metrics

```
WHERE k8s.pod.memory.working_set EXISTS
VISUALIZE COUNT
BREAKDOWN k8s.pod.name
LIMIT 20
```

**If checkout is missing:**
- Checkout pod might not be included in kubeletstats collection
- Check pod labels match kubeletstats filters (if any)

---

## Check Pod Labels and Selectors

### Verify Checkout Pod Exists

```bash
kubectl get pod -n otel-demo | grep checkout
```

### Check Pod Labels

```bash
kubectl get pod -n otel-demo -l app.kubernetes.io/name=checkout -o yaml | grep -A 20 "labels:"
```

**Should have labels like:**
- `app.kubernetes.io/name: checkout`
- `app.kubernetes.io/component: checkout`

---

## Alternative: Use Container-Level Metrics

If pod-level metrics aren't available, try container-level:

```
WHERE k8s.container.name = checkout
  AND k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.container.memory.working_set)
GROUP BY time(30s)
```

**Or:**
```
WHERE k8s.container.name = checkout
VISUALIZE MAX(k8s.container.memory.usage)
GROUP BY time(30s)
```

---

## Check Metric Namespace

The kubeletstats receiver might use different prefixes. Try:

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE COUNT
BREAKDOWN *
```

**Look for fields like:**
- `container.memory.*`
- `pod.memory.*`
- `k8s.container.memory.*`
- `k8s.pod.memory.*`

---

## Verify Checkout Pod Has Memory Limits

```bash
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
```

**If no limit is set:**
- Some metrics might not be collected
- `k8s.pod.memory.limit` will be null
- But `working_set` should still be available

---

## Test Query: Find Any Memory Data

```
WHERE k8s.pod.name STARTS_WITH checkout
  AND (
    k8s.pod.memory.working_set EXISTS
    OR k8s.pod.memory.usage EXISTS
    OR k8s.pod.memory.available EXISTS
    OR k8s.pod.memory.limit EXISTS
    OR k8s.pod.memory_limit_utilization EXISTS
    OR k8s.container.memory.working_set EXISTS
  )
VISUALIZE COUNT
GROUP BY time(1m)
```

**If this returns 0:**
- No memory metrics are being collected for checkout
- Check kubeletstats receiver configuration
- Check collector logs for errors

---

## Most Likely Solution

**Use `k8s.pod.memory.working_set` instead of `k8s.pod.memory.usage`:**

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(30s)
TIME RANGE: Last 1 hour
```

**This is the standard metric name from kubeletstats receiver.**

---

## If Still No Data

1. **Check collector is running:**
   ```bash
   kubectl get pod -n otel-demo | grep collector
   ```

2. **Check collector logs for errors:**
   ```bash
   kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector --tail=200 | grep -i error
   ```

3. **Verify kubeletstats receiver is in metrics pipeline:**
   ```bash
   kubectl get configmap otel-collector -n otel-demo -o yaml | grep -B 5 -A 10 "metrics:" | grep kubeletstats
   ```

4. **Check if checkout pod is in the right namespace:**
   ```bash
   kubectl get pod -n otel-demo | grep checkout
   ```
   Should be in `otel-demo` namespace.

5. **Restart collector to pick up config changes:**
   ```bash
   kubectl rollout restart deployment opentelemetry-collector -n otel-demo
   ```

---

**Last Updated:** December 2024  
**Status:** Diagnostic guide

