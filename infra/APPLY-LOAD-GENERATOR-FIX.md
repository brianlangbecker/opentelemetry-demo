# Fix Locust Crash at 50 Users

## Problem

Locust was crashing at ~50 users due to browser traffic being enabled. Each Chromium browser instance uses ~150MB RAM, causing OOMKill.

## Solution

Disabled browser traffic in `otel-demo-values-aws.yaml`:

- Uses lightweight HTTP requests instead
- Memory per user: ~20-30MB (vs 150MB with browsers)
- Can now scale to 100+ users per pod

## Apply the Fix

### Step 1: Authenticate to AWS

```bash
aws sso login --profile <your-profile>
```

### Step 2: Upgrade Helm Release

```bash
helm upgrade opentelemetry-demo open-telemetry/opentelemetry-demo \
  -f infra/otel-demo-values-aws.yaml \
  -n otel-demo
```

This will:

- Roll out new load-generator pods with `LOCUST_BROWSER_TRAFFIC_ENABLED=false`
- Restart the pods (takes ~1-2 minutes)

### Step 3: Verify the Fix

```bash
./infra/verify-load-generator.sh
```

This script checks:

- ✅ Pod status and health
- ✅ Browser traffic is disabled
- ✅ Memory limits are correct
- ✅ No OOMKilled events
- ✅ No errors in logs

### Step 4: Test with Higher User Count

Port-forward to access Locust UI:

```bash
kubectl port-forward -n otel-demo svc/load-generator 8089:8089
```

Open in browser: http://localhost:8089

**Try these loads:**

- **Conservative:** 50 users, spawn rate 5/sec
- **Moderate:** 100 users, spawn rate 10/sec
- **Aggressive:** 200 users, spawn rate 20/sec (with 3 replicas = 600 total)

## What Still Works

✅ **Full end-to-end testing** - all services exercised:

- Frontend (homepage, product pages)
- Product Catalog
- Recommendation Service
- Ad Service
- Cart Service
- **Checkout Service** ← Key flow
- Payment, Shipping, Currency, Email
- Kafka & Accounting

✅ **OpenTelemetry instrumentation** - traces, metrics, logs
✅ **Feature flags** - via FlagD integration
✅ **Chaos testing** - all chaos scenarios still work

## What You Lose

❌ Real browser JavaScript execution
❌ Frontend client-side RUM instrumentation
❌ UI click/interaction patterns (only 2 browser tasks anyway)

## Quick Health Check Commands

```bash
# Check pod status
kubectl get pods -n otel-demo -l app.kubernetes.io/component=load-generator

# Check browser traffic setting
kubectl get pod -n otel-demo -l app.kubernetes.io/component=load-generator -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="LOCUST_BROWSER_TRAFFIC_ENABLED")].value}'

# Watch memory usage
kubectl top pods -n otel-demo -l app.kubernetes.io/component=load-generator --watch

# Check for OOMKills
kubectl get events -n otel-demo --field-selector reason=OOMKilling --sort-by='.lastTimestamp'
```

## Rollback (if needed)

To re-enable browser traffic:

```yaml
# In otel-demo-values-aws.yaml
components:
  load-generator:
    envOverrides:
      - name: LOCUST_BROWSER_TRAFFIC_ENABLED
        value: 'true' # Change to true
    resources:
      limits:
        memory: 12Gi # Increase significantly
```

Then run `helm upgrade` again.
