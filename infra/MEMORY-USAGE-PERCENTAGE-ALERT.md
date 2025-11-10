# Memory Usage Percentage Calculation & Alert (>90%)

**Purpose:** Calculate memory usage as a percentage of the limit and alert when it exceeds 90%.

---

## Quick Start: Create Derived Column

### Step 1: Create Calculated Field in Honeycomb

1. **Go to Honeycomb UI** → Your dataset → **Columns** → **Create Column**

2. **Column Name:** `memory_usage_percent`

3. **Formula (if memory.limit is available):**
   ```
   IF(
     $k8s.pod.memory.limit > 0,
     ($k8s.pod.memory.usage / $k8s.pod.memory.limit) * 100,
     null
   )
   ```

   **What this does:**
   - Calculates: `(usage / limit) * 100` for each row
   - Only calculates if limit exists and > 0
   - Returns `null` if limit not available
   - **Result:** Memory usage as percentage (0-100%)

4. **If memory.limit is NOT available, use utilization metric:**
   
   If `k8s.pod.memory_limit_utilization` exists (already a percentage 0.0-1.0):
   ```
   $k8s.pod.memory_limit_utilization * 100
   ```
   
   **Or check if it exists first:**
   ```
   IF(
     $k8s.pod.memory_limit_utilization EXISTS,
     $k8s.pod.memory_limit_utilization * 100,
     null
   )
   ```

5. **Click "Create"**

**Alternative (with explicit null checks for usage/limit):**
```
IF(
  AND(
    $k8s.pod.memory.usage EXISTS,
    $k8s.pod.memory.limit EXISTS,
    $k8s.pod.memory.limit > 0
  ),
  ($k8s.pod.memory.usage / $k8s.pod.memory.limit) * 100,
  null
)
```

---

## Step 2: Query Memory Usage

### Basic Query

```
WHERE memory_usage_percent EXISTS
VISUALIZE MAX(memory_usage_percent) AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

### Query with Details

```
WHERE memory_usage_percent EXISTS
VISUALIZE
  MAX(memory_usage_percent) AS "Memory Usage %",
  MAX(k8s.pod.memory.usage) AS "Memory Used (bytes)",
  MAX(k8s.pod.memory.limit) AS "Memory Limit (bytes)"
GROUP BY k8s.pod.name, time(1m)
ORDER BY "Memory Usage %" DESC
```

---

## Step 3: Alert for >90%

### Query for Alert

```
WHERE memory_usage_percent > 90
VISUALIZE MAX(memory_usage_percent)
GROUP BY k8s.pod.name, time(1m)
```

### Alert Configuration

- **Name:** Pod Memory Usage > 90%
- **Frequency:** 60 seconds (1 minute)
- **Threshold:** `MAX(memory_usage_percent) > 90`
- **Alert Type:** `on_true`
- **Severity:** WARNING

### Alert Message

```
⚠️ High Memory Usage Detected

Pod: {{k8s.pod.name}}
Service: {{service_name_from_pod}}
Memory Usage: {{MAX(memory_usage_percent)}}%
Memory Used: {{MAX(k8s.pod.memory.usage)}} bytes
Memory Limit: {{MAX(k8s.pod.memory.limit)}} bytes (if available)

Action: 
- Check for memory leaks
- Review recent deployments
- Consider increasing memory limit
- Check for OOM kill events
```

---

## Available Memory Metrics

Kubernetes pod metrics include:

- `k8s.pod.memory.usage` - Current memory usage (bytes) ✅
- `k8s.pod.memory.working_set` - Working set memory (bytes) - alternative to usage
- `k8s.pod.memory.limit` - Memory limit (bytes) - **may not always be present**
- `k8s.pod.memory_limit_utilization` - Memory usage as percentage (0.0 to 1.0) - **may already be available** ✅

---

## Alternative: Use Existing Utilization Metric

If `k8s.pod.memory_limit_utilization` exists, you can use it directly:

### Query

```
WHERE k8s.pod.memory_limit_utilization EXISTS
VISUALIZE MAX(k8s.pod.memory_limit_utilization) * 100 AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

**Note:** The metric is typically 0.0-1.0, so multiply by 100 for percentage.

### Alert

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

---

## Alternative: Calculate Directly in Query (No Derived Column)

If you prefer not to create a derived column:

### Query with Calculation

```
WHERE k8s.pod.memory.usage EXISTS
  AND k8s.pod.memory.limit EXISTS
  AND k8s.pod.memory.limit > 0
VISUALIZE (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100 AS "Memory Usage %"
GROUP BY k8s.pod.name, time(1m)
```

### Alert Query

```
WHERE k8s.pod.memory.usage EXISTS
  AND k8s.pod.memory.limit EXISTS
  AND k8s.pod.memory.limit > 0
  AND (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100 > 90
VISUALIZE (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100
GROUP BY k8s.pod.name, time(1m)
```

**Alert Configuration:**
- **Trigger:** `(MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100 > 90`
- **Frequency:** Every 1 minute
- **Severity:** WARNING

**Note:** If `k8s.pod.memory.limit` is not available, use `k8s.pod.memory_limit_utilization` instead (see Alternative section above).

---

## Dashboard Panels

### Memory Usage Percentage Over Time

```
WHERE memory_usage_percent EXISTS
VISUALIZE MAX(memory_usage_percent) AS "Memory Usage %"
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

### Memory Usage Heatmap

```
WHERE memory_usage_percent EXISTS
VISUALIZE HEATMAP(memory_usage_percent)
GROUP BY k8s.pod.name, time(5m)
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
   WHERE k8s.pod.memory.usage EXISTS
   VISUALIZE COUNT
   ```
   
   **Or check utilization metric:**
   ```
   WHERE k8s.pod.memory_limit_utilization EXISTS
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

### Derived Column Returns Null

1. **Check if memory.usage exists:**
   ```
   WHERE k8s.pod.memory.usage EXISTS
   VISUALIZE COUNT
   ```

2. **Check if memory_limit_utilization exists (easier option):**
   ```
   WHERE k8s.pod.memory_limit_utilization EXISTS
   VISUALIZE COUNT
   ```

3. **Check if both usage and limit exist:**
   ```
   WHERE k8s.pod.memory.usage EXISTS
     AND k8s.pod.memory.limit EXISTS
   VISUALIZE COUNT
   ```

4. **Check if limit is > 0:**
   ```
   WHERE k8s.pod.memory.limit > 0
   VISUALIZE COUNT
   ```

5. **Test the formula with sample data:**
   ```
   WHERE k8s.pod.memory.usage EXISTS
   VISUALIZE
     k8s.pod.memory.usage,
     k8s.pod.memory.limit,
     k8s.pod.memory_limit_utilization,
     memory_usage_percent
   LIMIT 20
   ```

**If limit is not available, use the utilization metric directly:**
```
WHERE k8s.pod.memory_limit_utilization EXISTS
VISUALIZE MAX(k8s.pod.memory_limit_utilization) * 100
GROUP BY k8s.pod.name, time(1m)
```

---

## Example: Complete Memory Monitoring Query

```
WHERE k8s.pod.name EXISTS
VISUALIZE
  MAX(k8s.pod.memory.usage) AS "Memory Used (bytes)",
  MAX(k8s.pod.memory.limit) AS "Memory Limit (bytes)",
  COALESCE(
    MAX(memory_usage_percent),
    MAX(k8s.pod.memory_limit_utilization) * 100,
    IF(
      MAX(k8s.pod.memory.limit) > 0,
      (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100,
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
