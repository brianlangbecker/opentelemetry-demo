# Troubleshooting: Gradual Memory Leak Not Working

**Problem:** Running the gradual checkout memory leak test but not seeing crashes or memory issues.

---

## Quick Diagnostic Checklist

Run these checks in order:

### 1. Verify Feature Flag is Enabled and Set Correctly

**Check flag value:**
```bash
curl http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems
```

**Expected:** Should return `{"value": 200}` or `{"value": 300}` (NOT 2000!)

**If wrong:**
1. Go to FlagD UI: http://localhost:4000
2. Find `kafkaQueueProblems` flag
3. Edit the "on" variant value to **300** (not 2000)
4. Set default variant to "on"
5. Save

**Verify in logs:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=50 | grep -i "kafkaQueueProblems"
```

**Expected:** Should see: `"Warning: FeatureFlag 'kafkaQueueProblems' is activated"`

---

### 2. Check Load Generator Configuration

**Verify Locust is running:**
- Go to: http://localhost:8089
- Check if test is running
- **Number of users should be 25** (not 50!)
- **Ramp up:** 3 users/second
- **Runtime:** At least 30 minutes

**If wrong:**
- Stop the test
- Edit settings: **25 users** (not 50)
- Start again

**Verify checkouts are happening:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=100 | grep -i "order placed" | wc -l
```

**Expected:** Should see increasing count of "order placed" messages.

---

### 3. Check Memory Limit

**Verify checkout has 20Mi limit:**
```bash
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
```

**Expected:** Should show `20Mi` or `20971520` (bytes)

**If wrong:**
```bash
kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"20Mi"}}}]}}}}'
```

---

### 4. Check Current Memory Usage

**Watch memory in real-time:**
```bash
watch -n 5 "kubectl top pod -n otel-demo | grep checkout"
```

**Expected pattern:**
- Starts at ~8Mi
- Should gradually increase over 10-20 minutes
- Should reach 18-20Mi before OOM

**If memory stays flat:**
- Flag might not be enabled (see step 1)
- Checkouts might not be happening (see step 2)
- Flag value might be too low (try 500 instead of 300)

---

### 5. Check Pod Status

**Check if pod is restarting:**
```bash
kubectl get pod -n otel-demo | grep checkout
```

**Look for:**
- `RESTARTS` count increasing
- `STATUS` showing `CrashLoopBackOff` or `OOMKilled`

**If no restarts after 20 minutes:**
- Memory might not be reaching limit
- Increase flag value to 500
- Increase users to 30

---

### 6. Verify Kafka is Running

**Check Kafka pod:**
```bash
kubectl get pod -n otel-demo | grep kafka
```

**Expected:** Should show `Running`

**If not running:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=kafka --tail=50
```

---

### 7. Check Honeycomb Queries

**Query 1: Memory Usage**
```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.usage)
GROUP BY time(30s)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Should see gradual upward trend
- Should reach 18-20Mi (or close to limit)

**Query 2: Checkout Request Rate**
```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Should see steady request rate
- If zero, checkouts aren't happening

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

## Common Issues and Fixes

### Issue 1: Flag Value Too Low

**Symptoms:**
- Memory grows very slowly
- Never reaches OOM after 30+ minutes

**Fix:**
- Increase flag value from 300 to 500 or 1000
- Keep users at 25

### Issue 2: Flag Value Too High

**Symptoms:**
- Memory spikes immediately (not gradual)
- Crashes in 60-90 seconds

**Fix:**
- Decrease flag value from 2000 to 300
- This is the spike scenario, not gradual leak

### Issue 3: No Checkouts Happening

**Symptoms:**
- Memory stays flat
- No "order placed" in logs

**Fix:**
- Check Locust is running
- Verify frontend is accessible
- Check if load generator is actually generating traffic
- Verify browser traffic is enabled in Locust

### Issue 4: Memory Limit Too High

**Symptoms:**
- Memory grows but never reaches limit
- No OOM kill

**Fix:**
- Verify limit is 20Mi (not higher)
- Or increase flag value to compensate

### Issue 5: Flag Not Enabled

**Symptoms:**
- No "kafkaQueueProblems" in logs
- Memory stays at baseline

**Fix:**
- Go to FlagD UI: http://localhost:4000
- Enable `kafkaQueueProblems` flag
- Set variant to "on" with value 300
- Restart checkout service if needed

---

## Step-by-Step Verification

Run these commands in order:

```bash
# 1. Check flag value
curl http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems

# 2. Check memory limit
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'

# 3. Check current memory
kubectl top pod -n otel-demo | grep checkout

# 4. Check pod status
kubectl get pod -n otel-demo | grep checkout

# 5. Check if flag is triggering
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=100 | grep -i "kafkaQueueProblems"

# 6. Check if checkouts are happening
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=100 | grep -i "order placed" | wc -l

# 7. Watch memory growth (run for 5 minutes)
watch -n 10 "kubectl top pod -n otel-demo | grep checkout"
```

---

## Expected Timeline

With **flag = 300** and **25 users**:

| Time | Memory | Status |
|------|--------|--------|
| 0m | 8Mi | Baseline |
| 3m | 10Mi | Growing |
| 6m | 12Mi | Steady climb |
| 9m | 14Mi | 70% utilization |
| 12m | 16Mi | 80% utilization |
| 15m | 18Mi | 90% utilization |
| 18m | 19Mi | Critical |
| 20m | 20Mi+ | **OOM Kill** |

**If your timeline is different:**
- Faster growth = flag too high or users too many
- No growth = flag not enabled or no checkouts
- Growth but no OOM = limit too high or need more time

---

## Quick Fix: Restart Everything

If nothing works, restart the test:

```bash
# 1. Stop Locust load test
# Go to http://localhost:8089 and click Stop

# 2. Disable flag
# Go to http://localhost:4000 and set kafkaQueueProblems to "off"

# 3. Restart checkout service
kubectl rollout restart deployment checkout -n otel-demo

# 4. Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=checkout -n otel-demo --timeout=60s

# 5. Enable flag with correct value
# Go to http://localhost:4000
# Set kafkaQueueProblems "on" variant = 300
# Set default variant = "on"

# 6. Start Locust with 25 users
# Go to http://localhost:8089
# Set users = 25, ramp = 3, runtime = 30m
# Click Start

# 7. Watch memory
watch -n 10 "kubectl top pod -n otel-demo | grep checkout"
```

---

## Still Not Working?

**Check these advanced diagnostics:**

1. **Verify goroutines are being created:**
   ```
   WHERE service.name = checkout AND metric.name = "process.runtime.go.goroutines"
   VISUALIZE MAX(value)
   GROUP BY time(30s)
   ```
   Should see increasing goroutine count.

2. **Check Kafka message rate:**
   ```bash
   kubectl logs -n otel-demo -l app.kubernetes.io/name=kafka --tail=100 | grep -i "messages"
   ```

3. **Verify feature flag service is accessible:**
   ```bash
   kubectl exec -n otel-demo -l app.kubernetes.io/name=checkout -- curl -s http://flagd:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems
   ```

4. **Check checkout service logs for errors:**
   ```bash
   kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=200 | grep -i "error\|panic\|fatal"
   ```

---

**Last Updated:** December 2024  
**Status:** Troubleshooting guide

