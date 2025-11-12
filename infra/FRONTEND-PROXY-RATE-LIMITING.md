# Frontend Proxy Rate Limiting

The frontend-proxy service uses Envoy's local rate limiting filter to protect backend services from overload.

## Current Configuration

Rate limiting is **already enabled** in the `envoy-config` ConfigMap with these settings:

```yaml
token_bucket:
  max_tokens: 500
  tokens_per_fill: 500
  fill_interval: 60s  # 500 requests per minute
```

**What this means**:
- Maximum burst: 500 requests instantly
- Sustained rate: 500 requests per minute (≈8.3 req/sec)
- Rate-limited requests return: HTTP 429 with header `x-local-rate-limit: true`

## How Rate Limiting Works

The frontend-proxy uses Envoy's **token bucket algorithm**:

1. **Bucket starts full** with `max_tokens` (500)
2. **Each request consumes 1 token**
3. **Tokens refill** at rate: `tokens_per_fill` every `fill_interval` (500 every 60s)
4. **When bucket is empty**, requests are rejected with HTTP 429

This allows:
- **Burst traffic**: Handle up to 500 simultaneous requests
- **Sustained traffic**: 8.3 requests/second continuous
- **Gradual recovery**: Bucket refills at steady rate

## Modifying Rate Limits

### Option 1: Edit the ConfigMap Directly

```bash
kubectl edit configmap envoy-config -n otel-demo
```

Find the `envoy.filters.http.local_ratelimit` section and modify:

```yaml
token_bucket:
  max_tokens: 100          # Burst capacity (change this)
  tokens_per_fill: 50      # Refill amount (change this)
  fill_interval: 1s        # Refill interval (change this)
```

Then restart frontend-proxy to pick up changes:

```bash
kubectl rollout restart deployment/frontend-proxy -n otel-demo
kubectl rollout status deployment/frontend-proxy -n otel-demo
```

### Option 2: Update Source and Redeploy

The source configuration is in `src/frontend-proxy/envoy.tmpl.yaml`.

If you modify the source:
1. Build custom frontend-proxy image
2. Push to your registry
3. Update Helm values to use your custom image:

```yaml
components:
  frontend-proxy:
    image:
      repository: <your-registry>/frontend-proxy
      tag: rate-limit-custom
```

## Common Rate Limit Configurations

### Very restrictive (100 req/min)
```yaml
token_bucket:
  max_tokens: 100
  tokens_per_fill: 100
  fill_interval: 60s
```

### Moderate (1000 req/min)
```yaml
token_bucket:
  max_tokens: 1000
  tokens_per_fill: 1000
  fill_interval: 60s
```

### Per-second limiting (10 req/sec)
```yaml
token_bucket:
  max_tokens: 20      # Allow small burst
  tokens_per_fill: 10
  fill_interval: 1s
```

### High throughput (5000 req/min)
```yaml
token_bucket:
  max_tokens: 5000
  tokens_per_fill: 5000
  fill_interval: 60s
```

## Testing Rate Limiting

### Test with curl loop
```bash
# Generate requests quickly
for i in {1..600}; do
  curl -s -o /dev/null -w "Request $i: %{http_code}\n" \
    https://otel-demo.spicy.honeydemo.io/
  sleep 0.1
done
```

You should see HTTP 200s change to HTTP 429s once the token bucket is depleted.

### Check rate limit metrics

Rate limit stats are exposed on Envoy admin interface:

```bash
# Port-forward to Envoy admin
kubectl port-forward -n otel-demo deployment/frontend-proxy 9901:9901

# Check rate limit stats
curl -s http://localhost:9901/stats | grep rate_limit
```

Look for:
- `http_local_rate_limiter.enabled`: Total requests evaluated
- `http_local_rate_limiter.ok`: Requests that passed
- `http_local_rate_limiter.rate_limited`: Requests that were rate limited

### Query in Honeycomb

Rate-limited requests will have:
- `http.status_code = 429`
- `http.response.header.x_local_rate_limit = "true"`
- `service.name = "frontend-proxy"`

Query:
```
WHERE service.name = "frontend-proxy"
  AND http.status_code = 429
GROUP BY http.target
CALCULATE COUNT
```

## Path-Based Rate Limiting

The current configuration applies rate limiting globally. For path-specific limits, you would need to add `descriptors` to match specific routes:

```yaml
http_filters:
  - name: envoy.filters.http.local_ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
      stat_prefix: http_local_rate_limiter
      token_bucket:
        max_tokens: 500
        tokens_per_fill: 500
        fill_interval: 60s
      descriptors:
        # Stricter limit for /api endpoints
        - entries:
            - key: header_match
              value: "api"
          token_bucket:
            max_tokens: 50
            tokens_per_fill: 50
            fill_interval: 60s
      # ... rest of config
```

Note: This requires route configuration changes to set descriptor values.

## Disabling Rate Limiting

To disable rate limiting without removing the filter:

```bash
kubectl edit configmap envoy-config -n otel-demo
```

Change `filter_enforced` numerator to 0:

```yaml
filter_enforced:
  runtime_key: local_rate_limit_enforced
  default_value:
    numerator: 0      # Change from 100 to 0
    denominator: HUNDRED
```

This keeps the filter active for metrics but doesn't reject requests.

## Observability

Rate limiting generates:
- **Metrics**: Envoy stats on admin port 9901
- **Traces**: Requests continue through pipeline (429s are traced)
- **Logs**: Envoy access logs show rate-limited requests

All 429 responses include:
- Response header: `x-local-rate-limit: true`
- Standard Envoy access log with response code 429
- OpenTelemetry trace span with `http.status_code=429`

## Architecture Note

The frontend-proxy is a **standalone Envoy proxy** (not an application with Istio sidecar). This means:

- ✅ Rate limiting is configured directly in Envoy config (envoy-config ConfigMap)
- ❌ Cannot use Istio EnvoyFilter CRD (that only affects Istio sidecars)
- ✅ Changes require editing ConfigMap and restarting pod
- ✅ Envoy admin interface available on port 9901 for metrics/stats

## References

- [Envoy Local Rate Limit Filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/local_rate_limit_filter)
- [Token Bucket Algorithm](https://en.wikipedia.org/wiki/Token_bucket)
- Frontend-proxy source: `src/frontend-proxy/envoy.tmpl.yaml`
- Runtime config: `envoy-config` ConfigMap in `otel-demo` namespace
