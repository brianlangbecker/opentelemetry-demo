# Why Memory Isn't Growing - Diagnostic Checklist

**Problem:** Flag is enabled, Locust has 25 users, but checkout memory isn't growing.

---

## Quick Diagnostic

```bash
echo "=== Services ==="
kubectl get pod -n otel-demo | grep -E "checkout|kafka|load-generator"

echo -e "\n=== Memory ==="
kubectl top pod -n otel-demo | grep checkout

echo -e "\n=== Flag ==="
kubectl get configmap flagd-config -n otel-demo -o jsonpath='{.data.demo\.flagd\.json}' | jq '.flags.kafkaQueueProblems | {defaultVariant, on_value: .variants.on}'

echo -e "\n=== Orders ==="
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=200 | grep -i "order placed" | wc -l

echo -e "\n=== Flag Activation ==="
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=50 | grep -i "kafkaQueueProblems"
```

---

## Common Issues

### Issue 1: No Checkouts Happening (Most Common)

**Symptoms:**
- Memory stays at baseline (~6-8Mi)
- 0 orders in checkout logs
- No flag activation messages

**Diagnosis:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=200 | grep -i "order placed" | wc -l
# Returns: 0
```

**Causes:**
1. **Locust not actually running** - Check Locust UI
2. **Frontend not accessible** - Check frontend service
3. **Load generator not generating traffic** - Check Locust logs
4. **Users not completing checkout** - Check if users are browsing vs. checking out

**Fix:**
1. Go to Locust UI: http://localhost:8089
2. Verify test is **running** (green "Stop" button)
3. Check **Number of users:** Should show 25
4. Check **Total Requests:** Should be increasing
5. Verify **Browser traffic is enabled** in Locust settings

---

### Issue 2: Flag Not Being Read

**Symptoms:**
- Checkouts happening (orders in logs)
- But no "kafkaQueueProblems" activation message
- Memory not growing

**Diagnosis:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=100 | grep -i "kafkaQueueProblems"
# Returns: nothing
```

**Causes:**
1. **FlagD not accessible** - Checkout can't reach flagd service
2. **Flag cached** - Checkout service cached old flag value
3. **Flag not enabled** - ConfigMap has wrong value

**Fix:**
```bash
# Restart checkout to pick up flag
kubectl rollout restart deployment checkout -n otel-demo

# Verify flag is enabled
kubectl get configmap flagd-config -n otel-demo -o jsonpath='{.data.demo\.flagd\.json}' | jq '.flags.kafkaQueueProblems'

# Check if checkout can reach flagd
kubectl get pod -n otel-demo -l app.kubernetes.io/name=checkout -o jsonpath='{.items[0].metadata.name}' | xargs -I {} kubectl exec -n otel-demo {} -- curl -s http://flagd:8016/ofrep/v1/evaluate/flags/kafkaQueueProblems
```

---

### Issue 3: Memory Limit Too High

**Symptoms:**
- Memory growing slowly
- Never reaches limit
- No OOM kill

**Diagnosis:**
```bash
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# Returns: 50Mi or higher (too high)
```

**Fix:**
```bash
# Set to 20Mi
kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"20Mi"}}}]}}}}'
kubectl rollout restart deployment checkout -n otel-demo
```

---

### Issue 4: Flag Value Too Low

**Symptoms:**
- Memory growing very slowly
- Takes 30+ minutes to reach limit

**Diagnosis:**
```bash
kubectl get configmap flagd-config -n otel-demo -o jsonpath='{.data.demo\.flagd\.json}' | jq '.flags.kafkaQueueProblems.variants.on'
# Returns: 100 or lower (too low)
```

**Fix:**
```bash
# Increase to 1000
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | .data."demo.flagd.json".flags.kafkaQueueProblems.variants.on = 1000 | .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo
```

---

### Issue 5: Checkout Service Not Ready

**Symptoms:**
- Pod shows "Running" but not ready
- No logs or activity

**Diagnosis:**
```bash
kubectl get pod -n otel-demo | grep checkout
# Shows: 1/2 Ready (not 2/2)
```

**Fix:**
```bash
# Check why not ready
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=checkout | grep -A 10 "Conditions:"

# Check logs for errors
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=50
```

---

## Step-by-Step Verification

### Step 1: Verify Services Are Running

```bash
kubectl get pod -n otel-demo | grep -E "checkout|kafka|flagd|load-generator"
```

**Expected:** All should show `Running` with `2/2` or `3/3` ready

### Step 2: Verify Flag Is Enabled

```bash
kubectl get configmap flagd-config -n otel-demo -o jsonpath='{.data.demo\.flagd\.json}' | jq '.flags.kafkaQueueProblems'
```

**Expected:**
```json
{
  "defaultVariant": "on",
  "variants": {
    "on": 1000
  }
}
```

### Step 3: Verify Checkouts Are Happening

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=200 | grep -i "order placed" | wc -l
```

**Expected:** Should be > 0 (increasing count)

### Step 4: Verify Flag Is Activating

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=100 | grep -i "kafkaQueueProblems"
```

**Expected:** Should see:
```
Warning: FeatureFlag 'kafkaQueueProblems' is activated, overloading queue now.
Done with #1000 messages for overload simulation.
```

### Step 5: Verify Memory Is Growing

```bash
watch -n 10 "kubectl top pod -n otel-demo | grep checkout"
```

**Expected:** Memory should gradually increase from ~6Mi toward 20Mi

---

## Complete Reset Procedure

If nothing works, do a complete reset:

```bash
# 1. Stop Locust (if running)
# Go to http://localhost:8089 and click "Stop"

# 2. Disable flag temporarily
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | .data."demo.flagd.json".flags.kafkaQueueProblems.defaultVariant = "off" | .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

# 3. Restart all services
kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo

# 4. Wait for services to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=flagd -n otel-demo --timeout=60s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=checkout -n otel-demo --timeout=60s

# 5. Verify memory is at baseline
kubectl top pod -n otel-demo | grep checkout
# Should show ~6-8Mi

# 6. Enable flag with correct value
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | 
      .data."demo.flagd.json".flags.kafkaQueueProblems.variants.on = 1000 | 
      .data."demo.flagd.json".flags.kafkaQueueProblems.defaultVariant = "on" | 
      .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

# 7. Restart flagd and checkout
kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo

# 8. Wait for ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=flagd -n otel-demo --timeout=60s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=checkout -n otel-demo --timeout=60s

# 9. Verify flag is active
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout --tail=20 | grep -i "kafkaQueueProblems"

# 10. Start Locust with 25 users
# Go to http://localhost:8089
# Set users = 25, ramp = 3, runtime = 30m
# Click "Start"

# 11. Watch memory grow
watch -n 10 "kubectl top pod -n otel-demo | grep checkout"
```

---

## Expected Timeline

With flag=1000, limit=20Mi, and 25 users:

| Time | Memory | What's Happening |
|------|--------|------------------|
| 0m | 6-8Mi | Baseline, flag enabled, load starts |
| 1m | 8-10Mi | First checkouts, flag activates |
| 3m | 10-12Mi | Memory climbing |
| 5m | 12-15Mi | Steady growth |
| 7m | 15-18Mi | Approaching limit |
| 8m | 18-20Mi | Critical |
| 9m | 20Mi+ | **OOM Kill** → Restart → 6Mi |

---

**Last Updated:** December 2024  
**Status:** Diagnostic guide

