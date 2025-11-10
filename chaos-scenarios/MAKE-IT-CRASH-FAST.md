# Make Checkout Crash Faster

**Quick guide to adjust settings to make checkout service crash/OOM kill faster.**

---

## Current Status Check

```bash
echo "=== Services ==="
kubectl get pod -n otel-demo | grep -E "checkout|flagd|kafka"

echo -e "\n=== Memory ==="
kubectl top pod -n otel-demo | grep checkout

echo -e "\n=== Flag Value ==="
kubectl get configmap flagd-config -n otel-demo -o jsonpath='{.data.demo\.flagd\.json}' | jq '.flags.kafkaQueueProblems.variants.on'

echo -e "\n=== Memory Limit ==="
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
```

---

## Option 1: Increase Flag Value (Easiest)

**Current:** Flag value = 300 (gradual leak, 15-20 min to crash)

**To crash faster:**

### Set Flag to 1000 (Fast Crash - 5-7 minutes)

```bash
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | 
      .data."demo.flagd.json".flags.kafkaQueueProblems.variants.on = 1000 | 
      .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo
```

### Set Flag to 2000 (Immediate Crash - 60-90 seconds)

```bash
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | 
      .data."demo.flagd.json".flags.kafkaQueueProblems.variants.on = 2000 | 
      .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo
```

**Expected timeline:**
- **1000:** Memory reaches 20Mi in 5-7 minutes → OOM Kill
- **2000:** Memory spikes to 20Mi in 60-90 seconds → OOM Kill

---

## Option 2: Reduce Memory Limit (Very Fast)

**Current:** Memory limit = 20Mi

**To crash faster, reduce to 10Mi:**

```bash
kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"10Mi"}}}]}}}}'

kubectl rollout restart deployment checkout -n otel-demo
```

**Expected:** Memory reaches 10Mi much faster → OOM Kill in 3-5 minutes (with flag=300)

---

## Option 3: Increase Load (More Checkouts = Faster Growth)

**Current:** 25 users (gradual)

**To crash faster:**
- Go to Locust: http://localhost:8089
- Increase **Number of users** to 50
- More checkouts = more goroutines = faster memory growth

**Expected:** With flag=300 and 50 users, crashes in 8-12 minutes instead of 15-20

---

## Option 4: Combine All (Fastest Crash)

**Do all three:**
1. Set flag to 1000
2. Reduce memory limit to 10Mi
3. Increase users to 50

**Expected:** Crashes in 2-3 minutes

---

## Quick Commands Summary

### Fast Crash (5-7 minutes)
```bash
# Set flag to 1000
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | .data."demo.flagd.json".flags.kafkaQueueProblems.variants.on = 1000 | .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo
```

### Immediate Crash (60-90 seconds)
```bash
# Set flag to 2000
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | .data."demo.flagd.json".flags.kafkaQueueProblems.variants.on = 2000 | .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo
```

### Reduce Memory Limit (10Mi)
```bash
kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"10Mi"}}}]}}}}'
kubectl rollout restart deployment checkout -n otel-demo
```

---

## Verify It's Working

**Watch memory grow:**
```bash
watch -n 5 "kubectl top pod -n otel-demo | grep checkout"
```

**Watch for crash:**
```bash
kubectl get pod -n otel-demo -l app.kubernetes.io/name=checkout -w
```

**Check logs for flag activation:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout -f | grep -i "kafkaQueueProblems"
```

---

## Expected Timelines

| Flag Value | Memory Limit | Users | Time to Crash |
|-------------|--------------|-------|---------------|
| 300 | 20Mi | 25 | 15-20 min (gradual) |
| 500 | 20Mi | 25 | 8-12 min |
| 1000 | 20Mi | 25 | 5-7 min |
| 2000 | 20Mi | 25 | 60-90 sec (spike) |
| 300 | 10Mi | 25 | 3-5 min |
| 1000 | 10Mi | 50 | 2-3 min |

---

## Restore to Gradual Leak

**To go back to gradual leak:**
```bash
# Set flag back to 300
kubectl get configmap flagd-config -n otel-demo -o json | \
  jq '.data."demo.flagd.json" |= fromjson | .data."demo.flagd.json".flags.kafkaQueueProblems.variants.on = 300 | .data."demo.flagd.json" |= tostring' | \
  kubectl apply -f -

# Restore memory limit to 20Mi
kubectl patch deployment checkout -n otel-demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout","resources":{"limits":{"memory":"20Mi"}}}]}}}}'

kubectl rollout restart deployment flagd -n otel-demo
kubectl rollout restart deployment checkout -n otel-demo
```

---

**Last Updated:** December 2024  
**Status:** Quick reference guide

