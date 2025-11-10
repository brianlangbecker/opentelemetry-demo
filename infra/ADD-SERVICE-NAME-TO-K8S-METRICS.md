# Adding service.name to Kubernetes Pod Metrics

**Problem:** Kubernetes pod metrics (from `kubeletstats` and `k8s_cluster` receivers) don't have `service.name` by default, making it hard to filter and group by service.

**Solution Options:**
1. **Honeycomb Derived Column (Recommended)** - Extract from pod label in Honeycomb UI
2. **OpenTelemetry Collector** - Map in collector configuration (more complex)

---

## Option 1: Honeycomb Derived Column (Recommended) ⭐

**Simplest approach** - Create a calculated field in Honeycomb that extracts `service.name` from the pod label.

### Step 1: Verify Pod Label is Available

First, check if the pod label is being extracted by the k8sattributes processor:

**Query:**
```
WHERE k8s.pod.labels.app.kubernetes.io/name EXISTS
VISUALIZE COUNT
BREAKDOWN k8s.pod.labels.app.kubernetes.io/name
LIMIT 20
```

**If the label isn't available**, you need to add label extraction to the k8sattributes processor (see Option 2, Step 1).

### Step 2: Create Derived Column in Honeycomb

1. **Go to Honeycomb UI** → Your dataset → **Columns** → **Create Column**

2. **Column Name:** `service_name_from_pod`

3. **Formula:**
   ```
   $k8s.pod.labels.app.kubernetes.io/name
   ```

   **Alternative (if label format is different):**
   ```
   $k8s.pod.labels["app.kubernetes.io/name"]
   ```

4. **Click "Create"**

### Step 3: Use in Queries

Now you can filter and group by the derived column:

```
WHERE service_name_from_pod = "aws-load-balancer-controller"
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY k8s.pod.name, time(1m)
```

### Step 4: (Optional) Create Alias for service.name

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

