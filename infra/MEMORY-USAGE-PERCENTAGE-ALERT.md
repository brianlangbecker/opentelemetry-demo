# Memory Usage Percentage Calculation & Alert (>90%)

**Purpose:** Calculate memory usage as a percentage of the limit and alert when it exceeds 90%.

---

## Available Memory Metrics

Kubernetes pod metrics include:

- `k8s.pod.memory.working_set` - Current memory usage (bytes)
- `k8s.pod.memory.limit` - Memory limit (bytes) - may not always be present
- `k8s.pod.memory_limit_utilization` - Memory usage as percentage (0.0 to 1.0) - **may already be available**

---

## Option 1: Use Existing Utilization Metric (If Available)

If `k8s.pod.memory_limit_utilization` exists, you can use it directly:

### Query Memory Usage Percentage

```
WHERE k8s.pod.memory_limit_utilization EXISTS
VISUALIZE MAX(k8s.pod.memory_limit_utilization) * 100 AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

**Note:** The metric is typically 0.0-1.0, so multiply by 100 for percentage.

### Alert for >90%

**Query:**
```
WHERE k8s.pod.memory_limit_utilization > 0.9
VISUALIZE MAX(k8s.pod.memory_limit_utilization) * 100
GROUP BY k8s.pod.name, time(1m)
```

**Alert Configuration:**
- **Trigger:** `MAX(k8s.pod.memory_limit_utilization) * 100 > 90`
- **Frequency:** Every 1 minute
- **Severity:** WARNING
- **Message:**
  ```
  ⚠️ High Memory Usage
  
  Pod: {{k8s.pod.name}}
  Memory Usage: {{MAX(k8s.pod.memory_limit_utilization) * 100}}%
  
  Action: Check for memory leaks or increase memory limit
  ```

---

## Option 2: Calculate from Working Set and Limit

If `k8s.pod.memory_limit_utilization` is not available, calculate it manually.

### Step 1: Create Derived Column

1. **Go to Honeycomb UI** → Your dataset → **Columns** → **Create Column**

2. **Column Name:** `memory_usage_percent`

3. **Formula:**
   ```
   IF(
     $k8s.pod.memory.limit > 0,
     ($k8s.pod.memory.working_set / $k8s.pod.memory.limit) * 100,
     null
   )
   ```

   **What this does:**
   - Calculates: `(used / limit) * 100`
   - Only calculates if limit exists and > 0
   - Returns `null` if limit not available

4. **Click "Create"**

### Step 2: Query Memory Usage

```
WHERE memory_usage_percent EXISTS
VISUALIZE MAX(memory_usage_percent) AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

### Step 3: Alert for >90%

**Query:**
```
WHERE memory_usage_percent > 90
VISUALIZE MAX(memory_usage_percent)
GROUP BY k8s.pod.name, time(1m)
```

**Alert Configuration:**
- **Trigger:** `MAX(memory_usage_percent) > 90`
- **Frequency:** Every 1 minute
- **Severity:** WARNING
- **Message:**
  ```
  ⚠️ High Memory Usage
  
  Pod: {{k8s.pod.name}}
  Memory Usage: {{MAX(memory_usage_percent)}}%
  Memory Used: {{MAX(k8s.pod.memory.working_set)}} bytes
  Memory Limit: {{MAX(k8s.pod.memory.limit)}} bytes
  
  Action: Check for memory leaks or increase memory limit
  ```

---

## Option 3: Calculate Directly in Query (No Derived Column)

If you prefer not to create a derived column:

### Query with Calculation

```
WHERE k8s.pod.memory.working_set EXISTS
  AND k8s.pod.memory.limit EXISTS
  AND k8s.pod.memory.limit > 0
VISUALIZE (MAX(k8s.pod.memory.working_set) / MAX(k8s.pod.memory.limit)) * 100 AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

### Alert Query

```
WHERE k8s.pod.memory.working_set EXISTS
  AND k8s.pod.memory.limit EXISTS
  AND k8s.pod.memory.limit > 0
  AND (MAX(k8s.pod.memory.working_set) / MAX(k8s.pod.memory.limit)) * 100 > 90
VISUALIZE (MAX(k8s.pod.memory.working_set) / MAX(k8s.pod.memory.limit)) * 100
GROUP BY k8s.pod.name, time(1m)
```

**Alert Configuration:**
- **Trigger:** `(MAX(k8s.pod.memory.working_set) / MAX(k8s.pod.memory.limit)) * 100 > 90`
- **Frequency:** Every 1 minute
- **Severity:** WARNING

---

## Complete Alert Setup Example

### Alert: Pod Memory Usage > 90%

**Step 1: Create Query**

```
WHERE k8s.pod.memory_limit_utilization EXISTS
  OR (k8s.pod.memory.working_set EXISTS AND k8s.pod.memory.limit EXISTS)
VISUALIZE 
  COALESCE(
    MAX(k8s.pod.memory_limit_utilization) * 100,
    (MAX(k8s.pod.memory.working_set) / MAX(k8s.pod.memory.limit)) * 100
  ) AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

**Step 2: Create Trigger**

- **Name:** Pod Memory Usage > 90%
- **Frequency:** 60 seconds (1 minute)
- **Threshold:** `Memory Usage % > 90`
- **Alert Type:** `on_true`
- **Severity:** WARNING

**Step 3: Alert Message**

```
⚠️ High Memory Usage Detected

Pod: {{k8s.pod.name}}
Service: {{service_name_from_pod}}
Memory Usage: {{Memory Usage %}}%
Memory Used: {{MAX(k8s.pod.memory.working_set)}} bytes
Memory Limit: {{MAX(k8s.pod.memory.limit)}} bytes

Action: 
- Check for memory leaks
- Review recent deployments
- Consider increasing memory limit
- Check for OOM kill events
```

---

## Dashboard Panel

### Memory Usage Percentage Over Time

```
WHERE k8s.pod.memory_limit_utilization EXISTS
  OR (k8s.pod.memory.working_set EXISTS AND k8s.pod.memory.limit EXISTS)
VISUALIZE 
  COALESCE(
    MAX(k8s.pod.memory_limit_utilization) * 100,
    (MAX(k8s.pod.memory.working_set) / MAX(k8s.pod.memory.limit)) * 100
  ) AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

### Memory Usage by Service

```
WHERE memory_usage_percent EXISTS
VISUALIZE MAX(memory_usage_percent)
BREAKDOWN service_name_from_pod
GROUP BY time(5m)
```

### Top 10 Pods by Memory Usage

```
WHERE memory_usage_percent EXISTS
VISUALIZE MAX(memory_usage_percent)
BREAKDOWN k8s.pod.name
ORDER BY MAX(memory_usage_percent) DESC
LIMIT 10
```

---

## Troubleshooting

### Memory Limit Not Available

If `k8s.pod.memory.limit` is not present:

1. **Check if limit is set in Kubernetes:**
   ```bash
   kubectl get pod <pod-name> -o jsonpath='{.spec.containers[0].resources.limits.memory}'
   ```

2. **Use utilization metric if available:**
   ```
   WHERE k8s.pod.memory_limit_utilization EXISTS
   ```

3. **Or calculate from node memory:**
   ```
   (MAX(k8s.pod.memory.working_set) / MAX(k8s.node.memory.allocatable)) * 100
   ```

### Memory Usage Always 0 or Null

1. **Verify metrics are flowing:**
   ```
   WHERE k8s.pod.memory.working_set EXISTS
   VISUALIZE COUNT
   ```

2. **Check kubeletstats receiver is enabled:**
   ```bash
   kubectl get configmap otel-collector -n otel-demo -o yaml | grep kubeletstats
   ```

3. **Verify pod has memory limits set:**
   ```bash
   kubectl describe pod <pod-name> | grep -i "limits\|requests"
   ```

---

## Example: Complete Memory Monitoring Query

```
WHERE k8s.pod.name EXISTS
VISUALIZE
  MAX(k8s.pod.memory.working_set) AS "Memory Used (bytes)",
  MAX(k8s.pod.memory.limit) AS "Memory Limit (bytes)",
  COALESCE(
    MAX(k8s.pod.memory_limit_utilization) * 100,
    IF(
      MAX(k8s.pod.memory.limit) > 0,
      (MAX(k8s.pod.memory.working_set) / MAX(k8s.pod.memory.limit)) * 100,
      null
    )
  ) AS "Memory Usage %"
BREAKDOWN k8s.pod.name
GROUP BY time(1m)
ORDER BY "Memory Usage %" DESC
```

---

**Last Updated:** December 2024  
**Status:** Ready to use

