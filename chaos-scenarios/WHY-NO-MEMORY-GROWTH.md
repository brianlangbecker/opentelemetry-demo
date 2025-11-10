# Why Is Memory Not Growing in Checkout?

**Problem:** Running gradual memory leak test but not seeing memory growth in checkout service.

---

## Quick Diagnostic Checklist

Run these checks in order:

### 1. Verify Flag is Actually Enabled and Active

**Check flag value via API:**
```bash
curl -s http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems
```

**Expected:** Should return `{"value": 300}` (or your set value)

**If it returns `{"value": 0}` or `{"value": null}`:**
- Flag is not enabled
- Go to FlagD UI: http://localhost:4000
- Set `kafkaQueueProblems` default variant to "on"
- **Restart flagd** to pick up config changes:
  ```bash
  kubectl rollout restart deployment flagd -n otel-demo
  ```

**Check if checkout service can reach flagd:**
```bash
kubectl exec -n otel-demo -l app.kubernetes.io/name=checkout -- curl -s http://flagd:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems
```

---

### 2. Verify Flag is Being Read by Checkout Service

**Check checkout logs for flag activation:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=100 | grep -i "kafkaQueueProblems"
```

**Expected:** Should see:
```
Warning: FeatureFlag 'kafkaQueueProblems' is activated, overloading queue now.
Done with #300 messages for overload simulation.
```

**If you don't see this:**
- Flag is not being read
- Checkout service might be caching old flag value
- **Restart checkout service:**
  ```bash
  kubectl rollout restart deployment checkout -n otel-demo
  ```

---

### 3. Verify Checkouts Are Actually Happening

**Check if orders are being placed:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=100 | grep -i "order placed" | wc -l
```

**Expected:** Should see increasing count

**If count is 0:**
- No checkouts are happening
- Load generator might not be running
- Check Locust: http://localhost:8089
- Verify users are set (should be 25 for gradual leak)
- Verify test is actually running

**Check checkout request rate:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=200 | grep -i "PlaceOrder" | tail -20
```

---

### 4. Check Current Memory Usage

**Watch memory in real-time:**
```bash
watch -n 5 "kubectl top pod -n otel-demo | grep checkout"
```

**Expected pattern:**
- Should start at ~8Mi
- Should gradually increase over time
- Should reach 18-20Mi before OOM

**If memory stays flat at ~8Mi:**
- Flag is not triggering (see step 1-2)
- No checkouts happening (see step 3)
- Memory limit might be too high

**Check memory limit:**
```bash
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
```

**Expected:** Should show `20Mi`

---

### 5. Verify Load Generator is Running

**Check Locust UI:**
- Go to: http://localhost:8089
- Verify test is **running** (not stopped)
- Check **Number of users:** Should be 25 (not 50)
- Check **Ramp up:** Should be 3 users/second
- Check **Runtime:** Should be running for at least 10+ minutes

**If test is stopped:**
- Click "Start" button
- Set users to 25
- Set ramp up to 3
- Start test

---

### 6. Check Honeycomb Queries

**Query 1: Memory Usage Over Time**
```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Should see gradual upward trend
- Should start at ~8Mi (8,388,608 bytes)
- Should climb to 18-20Mi over 15-20 minutes

**If flat line:**
- Memory metrics might not be collected
- Check kubeletstats receiver (see step 7)

**Query 2: Checkout Request Rate**
```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Should see steady request rate
- Should be ~10-20 requests/minute with 25 users

**If zero:**
- No checkouts happening
- Check load generator

**Query 3: Flag Value in Traces**
```
WHERE service.name = checkout
VISUALIZE COUNT
BREAKDOWN feature_flag.kafkaQueueProblems
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Should see flag value = 300 (or your set value)
- If zero or null, flag isn't being read

---

### 7. Verify Metrics Collection

**Check if memory metrics are being collected:**
```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 15 minutes
```

**If this returns 0:**
- Metrics aren't being collected
- Check kubeletstats receiver

**Check collector logs:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector --tail=100 | grep -i "kubeletstats\|error"
```

**Check collector config:**
```bash
kubectl get configmap otel-collector -n otel-demo -o yaml | grep -A 10 "kubeletstats:"
```

**Should show:**
```yaml
kubeletstats:
  collection_interval: 20s
  metric_groups:
    - pod
```

---

## Common Issues and Fixes

### Issue 1: Flag Not Applied (Config Change Not Picked Up)

**Symptoms:**
- Flag value shows 0 in API
- No "kafkaQueueProblems" messages in logs

**Fix:**
```bash
# Restart flagd to pick up config changes
kubectl rollout restart deployment flagd -n otel-demo

# Wait for flagd to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=flagd -n otel-demo --timeout=60s

# Verify flag is now active
curl -s http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems

# Restart checkout to pick up new flag value
kubectl rollout restart deployment checkout -n otel-demo
```

---

### Issue 2: Checkout Service Caching Old Flag Value

**Symptoms:**
- Flag shows 300 in API
- But checkout logs show old value or no flag activation

**Fix:**
```bash
# Restart checkout service
kubectl rollout restart deployment checkout -n otel-demo

# Wait for it to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=checkout -n otel-demo --timeout=60s

# Check logs again
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=50 | grep -i "kafkaQueueProblems"
```

---

### Issue 3: No Checkouts Happening

**Symptoms:**
- Memory stays flat
- No "order placed" in logs
- Request rate is zero

**Fix:**
1. Go to Locust: http://localhost:8089
2. Verify test is **running** (green "Stop" button visible)
3. Check **Number of users:** Should be 25
4. If stopped, click "Start"
5. Verify browser traffic is enabled (if using browser mode)

**Check if frontend is accessible:**
```bash
kubectl get svc -n otel-demo | grep frontend
```

---

### Issue 4: Flag Value Too Low

**Symptoms:**
- Flag is enabled (value 100)
- Checkouts happening
- But memory grows very slowly (takes 30+ minutes)

**Fix:**
- Increase flag value to 300 or 500
- Go to FlagD UI: http://localhost:4000
- Edit `kafkaQueueProblems` "on" variant = 300
- Restart flagd and checkout

---

### Issue 5: Memory Limit Too High

**Symptoms:**
- Memory growing but never reaches limit
- No OOM kill after 30+ minutes

**Fix:**
```bash
# Check current limit
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'

# If it's higher than 20Mi, patch it:
kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"20Mi"}}}]}}}}'

# Restart to apply
kubectl rollout restart deployment checkout -n otel-demo
```

---

## Step-by-Step: Complete Reset and Restart

If nothing is working, do a complete reset:

```bash
# 1. Stop Locust test
# Go to http://localhost:8089 and click "Stop"

# 2. Disable flag temporarily
# Go to http://localhost:4000
# Set kafkaQueueProblems default variant = "off"

# 3. Restart flagd
kubectl rollout restart deployment flagd -n otel-demo
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=flagd -n otel-demo --timeout=60s

# 4. Restart checkout to clear any cached state
kubectl rollout restart deployment checkout -n otel-demo
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=checkout -n otel-demo --timeout=60s

# 5. Verify memory is back to baseline
kubectl top pod -n otel-demo | grep checkout
# Should show ~8Mi

# 6. Enable flag with correct value
# Go to http://localhost:4000
# Set kafkaQueueProblems "on" variant = 300
# Set default variant = "on"

# 7. Restart flagd again
kubectl rollout restart deployment flagd -n otel-demo
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=flagd -n otel-demo --timeout=60s

# 8. Restart checkout to pick up flag
kubectl rollout restart deployment checkout -n otel-demo
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=checkout -n otel-demo --timeout=60s

# 9. Verify flag is active
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=20 | grep -i "kafkaQueueProblems"
# Should see: "Warning: FeatureFlag 'kafkaQueueProblems' is activated"

# 10. Start Locust with 25 users
# Go to http://localhost:8089
# Set users = 25, ramp = 3, runtime = 30m
# Click "Start"

# 11. Watch memory grow
watch -n 10 "kubectl top pod -n otel-demo | grep checkout"
```

---

## Expected Timeline After Fix

With flag = 300 and 25 users:

| Time | Memory | What's Happening |
|------|--------|------------------|
| 0m | 8Mi | Baseline, flag enabled, load starts |
| 3m | 10Mi | Memory starting to climb |
| 6m | 12Mi | Steady growth |
| 9m | 14Mi | 70% utilization |
| 12m | 16Mi | 80% utilization |
| 15m | 18Mi | 90% utilization, GC pressure |
| 18m | 19Mi | Critical, latency spikes |
| 20m | 20Mi+ | **OOM Kill** → Restart → 8Mi |

---

## Quick Diagnostic Command

Run this to check everything at once:

```bash
echo "=== Flag Value ==="
curl -s http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems

echo -e "\n=== Checkout Memory ==="
kubectl top pod -n otel-demo | grep checkout

echo -e "\n=== Flag in Logs ==="
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=50 | grep -i "kafkaQueueProblems" | tail -3

echo -e "\n=== Order Count ==="
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=200 | grep -i "order placed" | wc -l

echo -e "\n=== Memory Limit ==="
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
echo
```

**Expected output:**
- Flag value: `{"value": 300}`
- Memory: Gradually increasing (10-20Mi)
- Flag in logs: "Warning: FeatureFlag 'kafkaQueueProblems' is activated"
- Order count: Increasing number
- Memory limit: `20Mi`

---

**Last Updated:** December 2024  
**Status:** Diagnostic guide

