# Adding service.name to Kubernetes Pod Metrics

**Problem:** Kubernetes pod metrics (from `kubeletstats` and `k8s_cluster` receivers) don't have `service.name` by default, making it hard to filter and group by service.

**Solution Options:**
1. **Honeycomb Derived Column (Recommended)** - Extract from pod label in Honeycomb UI
2. **OpenTelemetry Collector** - Map in collector configuration (more complex)

---

## Option 1: Honeycomb Derived Column (Recommended) ⭐

**Extract service name from pod name** - Create a calculated field that parses the service name from the pod name pattern.

### Pod Name Patterns

Kubernetes pod names typically follow these patterns:
- **Deployment:** `service-name-<hash>-<random>` → `service-name`
  - Example: `aws-load-balancer-controller-77ccf457d8-jxl52` → `aws-load-balancer-controller`
- **StatefulSet:** `service-name-<ordinal>` → `service-name`
  - Example: `postgresql-0` → `postgresql`
- **DaemonSet:** `service-name-<hash>` → `service-name`
  - Example: `kube-proxy-abc123` → `kube-proxy`

### Step 1: Create Derived Column

1. **Go to Honeycomb UI** → Your dataset → **Columns** → **Create Column**

2. **Column Name:** `service_name_from_pod`

3. **Formula (removes trailing hash/ordinal) - START HERE:**
   ```
   REGEX_REPLACE($k8s.pod.name, "-[a-f0-9]{8,10}-[a-z0-9]{5}$", "")
   ```
   
   **What this does:**
   - **Removes** Deployment pattern: `-<hash>-<random>` (e.g., `-77ccf457d8-jxl52`)
   - Uses regex to match 8-10 character hex hash + 5 character random suffix
   - **Result:** `aws-load-balancer-controller-77ccf457d8-jxl52` → `aws-load-balancer-controller` ✅
   
   **⚠️ Important:** Use `REGEX_REPLACE`, NOT `REG_VALUE`:
   - `REG_VALUE()` extracts the matched part (you'd get `-77ccf457d8-jxl52`) ❌
   - `REGEX_REPLACE()` removes the matched part (you get `aws-load-balancer-controller`) ✅

4. **If that doesn't work, try this simpler approach:**
   ```
   REGEX_REPLACE($k8s.pod.name, "-[0-9]+$", "")
   ```
   
   **What this does:**
   - Removes trailing numbers (StatefulSet ordinals like `-0`, `-1`)
   - Then manually handle Deployment pattern

5. **Most Robust Formula (handles all patterns):**
   ```
   IF(
     REGEX_MATCH($k8s.pod.name, "-[a-f0-9]{8,10}-[a-z0-9]{5}$"),
     REGEX_REPLACE($k8s.pod.name, "-[a-f0-9]{8-10}-[a-z0-9]{5}$", ""),
     IF(
       REGEX_MATCH($k8s.pod.name, "-[0-9]+$"),
       REGEX_REPLACE($k8s.pod.name, "-[0-9]+$", ""),
       REGEX_REPLACE($k8s.pod.name, "-[a-f0-9]{6,}$", "")
     )
   )
   ```

6. **Simplest Approach (split and rejoin):**
   ```
   JOIN(
     SLICE(SPLIT($k8s.pod.name, "-"), 0, LENGTH(SPLIT($k8s.pod.name, "-")) - 2),
     "-"
   )
   ```
   
   **What this does:**
   - Splits pod name by `-`
   - Takes all parts except last 2 (removes hash + random)
   - Rejoins with `-`
   - **Note:** This assumes Deployment pattern. For StatefulSet, use `-1` instead of `-2`

7. **Best Universal Formula (CORRECTED):**
   ```
   IF(
     REGEX_MATCH($k8s.pod.name, "-[a-f0-9]{8,10}-[a-z0-9]{5}$"),
     REGEX_REPLACE($k8s.pod.name, "-[a-f0-9]{8,10}-[a-z0-9]{5}$", ""),
     REGEX_REPLACE($k8s.pod.name, "-[0-9]+$", "")
   )
   ```
   
   **What this does:**
   - Checks if pod name matches Deployment pattern (hash + random)
   - If yes: **removes** `-<hash>-<random>` (keeps service name)
   - If no: **removes** trailing numbers (StatefulSet ordinal)
   
   **⚠️ Common Mistake:**
   - ❌ `REG_VALUE()` - **extracts** the matched pattern (gets hash/random)
   - ✅ `REGEX_REPLACE()` - **removes** the matched pattern (keeps service name)

### Step 2: Test the Formula

Test with your actual pod names:

```
WHERE k8s.pod.name EXISTS
VISUALIZE k8s.pod.name, service_name_from_pod
BREAKDOWN k8s.pod.name
LIMIT 20
```

**Verify the extraction:**
- `aws-load-balancer-controller-77ccf457d8-jxl52` → `aws-load-balancer-controller` ✅
- `postgresql-0` → `postgresql` ✅
- `checkout-bc8884986-59rzz` → `checkout` ✅

### Step 3: Use in Queries

Now you can filter and group by the derived column:

```
WHERE service_name_from_pod = "aws-load-balancer-controller"
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY k8s.pod.name, time(1m)
```

### Step 4: (Optional) Create Unified service.name Column

If you want to use `service.name` in queries (for consistency with application traces), create a second derived column:

1. **Column Name:** `service.name`

2. **Formula:**
   ```
   COALESCE($service.name, $service_name_from_pod)
   ```

   **What this does:**
   - Uses existing `service.name` if present (from application instrumentation)
   - Falls back to `service_name_from_pod` if not present (for K8s metrics)

3. **Now you can query:**
   ```
   WHERE service.name = "aws-load-balancer-controller"
   VISUALIZE MAX(k8s.pod.memory.working_set)
   ```

**Advantages:**
- ✅ No collector configuration changes needed
- ✅ Works with any pod name pattern
- ✅ Works immediately after creating the column
- ✅ Easy to modify or remove
- ✅ Can combine with existing `service.name` from app instrumentation

---

## Option 2: OpenTelemetry Collector Configuration

### Step 1: Extract Pod Label

In the `k8sattributes` processor, add label extraction:

```yaml
k8sattributes:
  passthrough: true
  extract:
    metadata:
      - k8s.namespace.name
      - k8s.deployment.name
      # ... other metadata ...
    labels:
      - tag_name: app.kubernetes.io/name
        key: app.kubernetes.io/name
        from: pod
```

**What this does:**
- Extracts the `app.kubernetes.io/name` label from pods
- Adds it as `k8s.pod.labels.app.kubernetes.io/name` attribute

### Step 2: Map Label to service.name

Add a resource processor to map the extracted label to `service.name`:

```yaml
resource/k8s_service_name:
  attributes:
    - key: service.name
      from_attribute: k8s.pod.labels.app.kubernetes.io/name
      action: upsert
```

**What this does:**
- Maps `k8s.pod.labels.app.kubernetes.io/name` → `service.name`
- Only sets `service.name` if the label exists (won't overwrite existing `service.name` from application instrumentation)

### Step 3: Add to Metrics Pipeline

Add the resource processor to the metrics pipeline **after** k8sattributes:

```yaml
service:
  pipelines:
    metrics:
      receivers:
        - kubeletstats
        - k8s_cluster
      processors:
        - k8sattributes          # Extracts pod labels
        - resource/k8s_service_name  # Maps to service.name
        - resource/prometheus
        - attributes/prometheus
      exporters:
        - otlp/honeycomb
```

---

## Result

After applying this configuration, Kubernetes pod metrics will have `service.name` populated from the pod label:

**Before:**
```
k8s.pod.name: aws-load-balancer-controller-77ccf457d8-jxl52
k8s.namespace.name: kube-system
(no service.name)
```

**After:**
```
k8s.pod.name: aws-load-balancer-controller-77ccf457d8-jxl52
k8s.namespace.name: kube-system
service.name: aws-load-balancer-controller  ✅
```

---

## Query Examples

Now you can filter and group by service:

```
WHERE service.name = "aws-load-balancer-controller"
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY k8s.pod.name, time(1m)
```

```
WHERE service.name EXISTS
VISUALIZE COUNT
BREAKDOWN service.name
GROUP BY time(5m)
```

---

## Troubleshooting: Label Not Available

If `k8s.pod.labels.app.kubernetes.io/name` doesn't exist, the k8sattributes processor needs to extract it. Add this to your collector config:

```yaml
k8sattributes:
  extract:
    labels:
      - tag_name: app.kubernetes.io/name
        key: app.kubernetes.io/name
        from: pod
```

Then upgrade your Helm release and the label will be available for the derived column.

---

## Alternative: Using Deployment Name

If pods don't have the `app.kubernetes.io/name` label, you can use the deployment name instead:

```yaml
resource/k8s_service_name:
  attributes:
    - key: service.name
      from_attribute: k8s.deployment.name
      action: upsert
```

**Note:** This works if deployment names match service names, but may not work for StatefulSets, DaemonSets, etc.

---

## Alternative: Using Multiple Labels

You can try multiple label sources and use the first one that exists:

```yaml
resource/k8s_service_name:
  attributes:
    - key: service.name
      from_attribute: k8s.pod.labels.app.kubernetes.io/name
      action: upsert
    - key: service.name
      from_attribute: k8s.pod.labels.app
      action: upsert
    - key: service.name
      from_attribute: k8s.deployment.name
      action: upsert
```

**Note:** Resource processor processes attributes in order, so the first match wins.

---

## Troubleshooting

### service.name Not Appearing

1. **Check if pods have the label:**
   ```bash
   kubectl get pod <pod-name> -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}'
   ```

2. **Check k8sattributes processor logs:**
   ```bash
   kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector | grep k8sattributes
   ```

3. **Verify label extraction:**
   ```
   WHERE k8s.pod.labels.app.kubernetes.io/name EXISTS
   VISUALIZE COUNT
   ```

4. **Check resource processor:**
   ```
   WHERE k8s.pod.labels.app.kubernetes.io/name EXISTS
     AND service.name EXISTS
   VISUALIZE COUNT
   ```

### Label Key with Special Characters

If the label key has dots or slashes (like `app.kubernetes.io/name`), the k8sattributes processor should handle it, but the attribute name might be:
- `k8s.pod.labels.app.kubernetes.io/name` (with dots and slash)
- Or converted to underscores: `k8s.pod.labels.app_kubernetes_io_name`

Check what attribute name is actually created by querying:
```
WHERE k8s.pod.labels.* EXISTS
VISUALIZE COUNT
BREAKDOWN k8s.pod.labels.*
```

---

## Applying the Configuration

After updating the Helm values files:

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values infra/otel-demo-values.yaml
```

**Verify:**
```bash
kubectl get configmap otel-collector -n otel-demo -o yaml | grep -A 5 "k8sattributes:"
kubectl get configmap otel-collector -n otel-demo -o yaml | grep -A 5 "resource/k8s_service_name:"
```

---

**Last Updated:** December 2024  
**Status:** Configuration added to Helm values files

