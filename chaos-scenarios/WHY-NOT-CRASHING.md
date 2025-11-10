# Why Is Checkout Not Crashing?

**Problem:** Memory leak test is running but checkout service is not crashing/OOM killing.

---

## Quick Diagnostic: Is Memory Actually Growing?

**Check current memory:**
```bash
kubectl top pod -n otel-demo | grep checkout
```

**Expected:** Should see memory gradually increasing from ~8Mi toward 20Mi

**If memory is flat or low:**
- Memory isn't growing → See "Why Is Memory Not Growing" guide
- Flag might not be enabled
- Checkouts might not be happening

**If memory IS growing but not crashing:**
- Continue with diagnostics below

---

## Why It Might Not Crash

### 1. Memory Limit Too High

**Check memory limit:**
```bash
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
```

**Expected:** Should be `20Mi` (20,971,520 bytes)

**If it's higher (e.g., 50Mi, 100Mi, or unlimited):**
- Memory will grow but never reach limit
- **Fix:** Set limit to 20Mi:
  ```bash
  kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"20Mi"}}}]}}}}'
  
  kubectl rollout restart deployment checkout -n otel-demo
  ```

---

### 2. Flag Value Too Low

**Check flag value:**
```bash
curl -s http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems
```

**Expected:** Should return `{"value": 300}` for gradual leak

**If it's 100 or lower:**
- Memory grows too slowly
- Takes 30-40+ minutes to reach limit
- **Fix:** Increase to 300 or 500:
  - Go to FlagD UI: http://localhost:4000
  - Edit `kafkaQueueProblems` "on" variant = 300
  - Restart flagd and checkout

---

### 3. Not Enough Load

**Check checkout request rate:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=200 | grep -i "order placed" | wc -l
```

**Expected:** Should see steady increase in count

**Check Locust:**
- Go to: http://localhost:8089
- Verify **Number of users:** 25 (for gradual) or 50 (for faster)
- If too low, increase users

**If request rate is too low:**
- Memory grows very slowly
- Takes much longer to reach limit
- **Fix:** Increase Locust users to 30-35

---

### 4. Not Enough Time

**Expected timeline with flag=300 and 25 users:**
- 0-5m: Memory climbs 8Mi → 12Mi
- 5-10m: Memory climbs 12Mi → 16Mi
- 10-15m: Memory climbs 16Mi → 18Mi
- 15-20m: Memory reaches 20Mi → **OOM Kill**

**If you've only been running for 5-10 minutes:**
- Memory might still be growing
- Give it more time (20-30 minutes total)

**Check how long it's been running:**
```bash
kubectl get pod -n otel-demo | grep checkout
# Check AGE column
```

---

### 5. Service Is Restarting But You're Not Seeing It

**Check restart count:**
```bash
kubectl get pod -n otel-demo | grep checkout
```

**Look at RESTARTS column:**
- If RESTARTS > 0, it IS crashing and restarting
- You might be missing the crash event

**Check for OOMKilled events:**
```bash
kubectl get events -n otel-demo --sort-by='.lastTimestamp' | grep -i "checkout\|oom" | tail -20
```

**Check pod status:**
```bash
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=checkout | grep -A 10 "Last State\|State:"
```

**Look for:**
- `Last State: Terminated`
- `Reason: OOMKilled`
- `Exit Code: 137`

---

### 6. Memory Growing But GC Keeping Up

**Check if memory is stuck at high level:**
```bash
watch -n 5 "kubectl top pod -n otel-demo | grep checkout"
```

**If memory is at 18-19Mi but not crashing:**
- Garbage collector might be keeping it just under limit
- **Fix:** Increase flag value to 500 or 1000 to create more pressure

---

## Diagnostic Queries in Honeycomb

### Query 1: Memory Growth Over Time

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.working_set)
GROUP BY time(1m)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Is memory growing? (should see upward trend)
- What's the current value? (should approach 20Mi = 20,971,520 bytes)
- Is it stuck at a certain level?

### Query 2: Memory Limit

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory.limit)
GROUP BY k8s.pod.name
TIME RANGE: Last 30 minutes
```

**What to look for:**
- What's the limit? (should be 20Mi = 20,971,520 bytes)
- If much higher, that's why it's not crashing

### Query 3: Memory Utilization

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.pod.memory_limit_utilization) * 100
GROUP BY time(1m)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Should approach 100% before crash
- If stuck at 80-90%, GC might be keeping it under limit

### Query 4: Pod Restarts

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE MAX(k8s.container.restarts)
GROUP BY k8s.pod.name
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Is restart count increasing?
- If yes, it IS crashing, you just missed it

### Query 5: Checkout Request Rate

```
WHERE service.name = checkout AND name = PlaceOrder
VISUALIZE COUNT
GROUP BY time(1m)
TIME RANGE: Last 30 minutes
```

**What to look for:**
- Is there steady traffic?
- Should be ~10-20 requests/minute with 25 users
- If too low, memory grows too slowly

---

## Force a Crash (For Testing)

If you want to see a crash immediately for testing:

### Option 1: Increase Flag Value Dramatically

```bash
# Set flag to 2000 (spike scenario)
# Go to FlagD UI: http://localhost:4000
# Edit kafkaQueueProblems "on" variant = 2000
# Restart flagd and checkout

kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo

# Watch memory spike
watch -n 2 "kubectl top pod -n otel-demo | grep checkout"
```

**Expected:** Memory spikes to 20Mi in 60-90 seconds → OOM Kill

### Option 2: Reduce Memory Limit

```bash
# Set limit to 10Mi (very low)
kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"10Mi"}}}]}}}}'

kubectl rollout restart deployment checkout -n otel-demo

# Watch memory hit limit faster
watch -n 5 "kubectl top pod -n otel-demo | grep checkout"
```

**Expected:** Memory reaches 10Mi much faster → OOM Kill

---

## Complete Diagnostic Command

Run this to check everything:

```bash
echo "=== Memory Limit ==="
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
echo

echo "=== Current Memory ==="
kubectl top pod -n otel-demo | grep checkout

echo -e "\n=== Pod Status & Restarts ==="
kubectl get pod -n otel-demo | grep checkout

echo -e "\n=== Flag Value ==="
curl -s http://localhost:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems

echo -e "\n=== Recent OOM Events ==="
kubectl get events -n otel-demo --sort-by='.lastTimestamp' | grep -i "checkout\|oom" | tail -5

echo -e "\n=== Pod Last State ==="
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=checkout | grep -A 5 "Last State" | head -10
```

**Expected output:**
- Memory limit: `20Mi`
- Current memory: 18-20Mi (approaching limit)
- Restarts: 0 or increasing
- Flag value: `{"value": 300}`
- OOM events: Recent OOMKilled events (if crashing)

---

## Most Common Issue: Memory Limit Too High

**If memory limit is 50Mi, 100Mi, or unlimited:**
- Memory will grow but never reach limit
- Service won't crash
- **Fix:** Set to 20Mi

**If memory limit is correct (20Mi) but still not crashing:**
- Check if memory is actually growing (see Query 1)
- Check if it's stuck at 18-19Mi (GC keeping it under)
- Increase flag value to create more pressure
- Give it more time (20-30 minutes total)

---

## Expected Behavior

**With flag=300 and 25 users:**

| Time | Memory | Status | What Happens |
|------|--------|--------|--------------|
| 0m | 8Mi | Normal | Baseline |
| 5m | 12Mi | Growing | Memory climbing |
| 10m | 16Mi | High | 80% utilization |
| 15m | 18Mi | Critical | 90% utilization, GC pressure |
| 18m | 19Mi | Pre-OOM | 95% utilization |
| 20m | 20Mi+ | **OOM** | **Killed by Kubernetes** |
| 20m+30s | 8Mi | Restarted | New pod, back to baseline |

**If your timeline is different:**
- Faster growth = flag too high or users too many
- Slower growth = flag too low or users too few
- No growth = flag not enabled or no checkouts

---

**Last Updated:** December 2024  
**Status:** Diagnostic guide

