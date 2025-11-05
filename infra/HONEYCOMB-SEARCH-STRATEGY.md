# Finding Metrics in Honeycomb - Alternative Strategies

## ❌ Problem: `job` attribute doesn't exist

The Prometheus receiver's `job` label may not be making it through to Honeycomb due to:

- Attribute processing/filtering
- OTLP conversion dropping labels
- Different attribute naming

## ✅ Alternative Ways to Find Your Metrics

### Strategy 1: Search for Service Names

In Honeycomb `opentelemetry-demo` dataset, try:

```
GROUP BY service.name
LIMIT 100
```

Look for these services (from your deployment):

- frontend
- cart
- checkout
- payment
- recommendation
- product-catalog
- shipping
- ad
- currency
- email
- accounting
- fraud-detection
- quote

### Strategy 2: Look for Kubernetes Attributes

Prometheus receiver with Kubernetes SD adds these attributes:

```
WHERE k8s.pod.name EXISTS
GROUP BY k8s.pod.name, k8s.namespace.name
```

or

```
WHERE k8s.namespace.name = "otel-demo"
GROUP BY k8s.pod.name
```

### Strategy 3: Search by Metric Name Pattern

List all metric names and look for patterns:

```
GROUP BY name
LIMIT 500
```

Filter for:

- Anything with "istio"
- Anything with "envoy" (Istio uses Envoy)
- Request/response metrics
- HTTP metrics

### Strategy 4: Check for Instance/Target Attributes

```
WHERE instance EXISTS
GROUP BY instance
```

or

```
GROUP BY __name__, instance
```

### Strategy 5: Filter by Time Range

If metrics just started flowing:

```
WHERE timestamp > [last 5 minutes]
GROUP BY name, service.name
```

### Strategy 6: Look for HIGH Cardinality Fields

Istio metrics have lots of labels. Look for fields with many unique values:

```
In Honeycomb UI:
1. Click any field in the left sidebar
2. Look for fields with high cardinality (100s-1000s of values)
3. These are likely prometheus metrics
```

Common high-card fields from Istio:

- `destination_workload`
- `source_workload`
- `response_code`
- `request_protocol`

## 🔍 What Metrics SHOULD Be There

Based on collector logs showing **850 metrics** in spike, you should have:

- kubeletstats metrics (~250)
- k8s_cluster metrics (~50)
- postgresql metrics (~10)
- **Prometheus/Istio metrics (~500+)** ← These are the new ones!

## 🎯 Simple Test Queries

### Query 1: Count All Metrics

```
COUNT
GROUP BY name
ORDER BY COUNT DESC
LIMIT 50
```

This shows your TOP 50 metrics by volume.

### Query 2: Find New Metrics

```
WHERE timestamp > [since collector restart: ~54 minutes ago]
GROUP BY name
```

### Query 3: Check for Prometheus Receiver Data

```
WHERE otelcol.receiver.name = "prometheus"
GROUP BY name
```

or

```
WHERE receiver = "prometheus"
GROUP BY name
```

### Query 4: Search All Attribute Names

In Honeycomb UI:

1. Go to "Add Filter" dropdown
2. Scroll through ALL available fields
3. Look for anything suspicious or new:
   - destination\_\*
   - source\_\*
   - response\_\*
   - istio\_\*
   - envoy\_\*
   - reporter
   - connection_security_policy

## 💡 If You Find Metrics But No Istio Data

The Prometheus receiver might not be discovering targets. Check:

1. **Service Account Permissions:**

```bash
kubectl describe clusterrole -n otel-demo | grep "otel-collector"
```

Should have `pods`, `nodes`, `endpoints` - get, list, watch

2. **Target Discovery:**

```bash
kubectl logs -n otel-demo deployment/otel-collector --tail=500 | grep -i "target\|discover\|scrape"
```

3. **Manual Scrape Test:**

```bash
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=frontend -o jsonpath='{.items[0].metadata.name}')
IP=$(kubectl get pod -n otel-demo $POD -o jsonpath='{.status.podIP}')
echo "Frontend pod IP: $IP"

# Try scraping from your machine (if you have access)
curl http://$IP:15020/stats/prometheus | grep istio_requests_total | head -5
```

## 🚨 Nuclear Option: Check Prometheus UI

The demo has Prometheus running. It should be scraping Istio too:

```bash
kubectl port-forward -n otel-demo svc/prometheus 9090:9090
```

Open: http://localhost:9090

Search for: `istio_requests_total`

**If Prometheus sees it but Honeycomb doesn't:**

- Issue is in OTel Collector export
- Check exporters in collector config
- Verify honeycomb exporter is in metrics pipeline

**If Prometheus DOESN'T see it:**

- Istio metrics aren't being exposed
- Service discovery issue
- RBAC permissions problem

## 📊 Expected Honeycomb Schema

Once working, you should see fields like:

**Attributes:**

- `destination_workload`: "frontend", "cart", "checkout"
- `source_workload`: "load-generator", "frontend"
- `response_code`: "200", "404", "500"
- `request_protocol`: "http", "grpc"
- `destination_service_name`: "frontend.otel-demo.svc.cluster.local"
- `k8s.pod.name`: "frontend-xxx"
- `k8s.namespace.name`: "otel-demo"

**Metric Names:**

- `istio_requests_total`
- `istio_request_duration_milliseconds_bucket`
- `istio_request_bytes_sum`
- `istio_response_bytes_sum`

---

**Try these queries and let me know what you find!** 🔍

Even if `job` doesn't exist, the Istio metrics should be there with Kubernetes attributes.
