# Istiod Crash or Restart - Chaos Testing Scenario

**Scenario Type:** Control Plane Disruption  
**Severity:** High  
**Duration:** 5-15 minutes  
**Purpose:** Test service mesh resilience when control plane is unavailable

---

## 📋 Overview

This chaos test simulates Istiod (Istio control plane) crashes or restarts to validate:

- Data plane continues functioning without control plane
- Configuration updates are delayed but services remain operational
- Observability catches control plane issues
- Recovery is automatic and complete

---

## 🎯 Testing Objectives

1. **Verify Data Plane Independence**

   - Existing traffic flows continue uninterrupted
   - Envoy sidecars use cached configuration
   - No service disruption during control plane outage

2. **Identify Configuration Delivery Issues**

   - New service deployments may not receive sidecar injection
   - Configuration updates (VirtualServices, DestinationRules) are queued
   - Can correlate degraded configuration delivery with Istiod downtime

3. **Validate Observability & Alerting**

   - Honeycomb captures Istiod pod restart events
   - Metrics show control plane unavailability
   - Alerts fire early before user impact

4. **Test Recovery Process**
   - Istiod pods restart automatically
   - Envoy sidecars reconnect and sync configuration
   - System returns to normal operation

---

## 🔧 Chaos Methods

### Method 1: Delete All Istiod Containers (Aggressive)

**Command:**

```bash
kubectl delete pods -n istio-system -l app=istiod
```

**Expected Behavior:**

- Istiod pods terminate immediately
- Kubernetes recreates pods automatically
- ~30-60 seconds of control plane unavailability
- Data plane (traffic) continues unaffected

**Recovery Time:** 30-90 seconds (pod startup + readiness)

---

### Method 2: Restart Istiod Containers (Graceful)

**Command:**

```bash
kubectl rollout restart deployment/istiod -n istio-system
```

**Expected Behavior:**

- Rolling restart maintains some control plane availability
- Graceful termination of old pods
- New pods start before old ones fully terminate
- Minimal configuration delivery disruption

**Recovery Time:** 60-120 seconds (rolling update)

---

### Method 3: Kill Istiod Process (Simulates Crash)

**Command:**

```bash
# Get pod name
ISTIOD_POD=$(kubectl get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].metadata.name}')

# Kill the main process
kubectl exec -n istio-system $ISTIOD_POD -- killall pilot-discovery
```

**Expected Behavior:**

- Simulates actual process crash
- Container restart policy triggers automatic recovery
- ~10-20 seconds of control plane unavailability
- Faster recovery than full pod deletion

**Recovery Time:** 10-30 seconds (container restart)

---

### Method 4: Scale Down Istiod (Complete Outage - Keep It Down)

**⚠️ Most Aggressive Test - Control Plane Stays Down Until You Restore It**

#### 🔻 Take Istiod Down (and keep it down)

**Step 1: Check current replica count**

```bash
# See how many replicas you currently have
kubectl get deployment istiod -n istio-system

# Save the current replica count for restoration later
ORIGINAL_REPLICAS=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.replicas}')
echo "Original replicas: $ORIGINAL_REPLICAS"
# Take note of this number!
```

**Step 2: Scale down to zero**

```bash
# Scale Istiod deployment to 0 replicas
kubectl scale deployment istiod -n istio-system --replicas=0

# Note timestamp for Honeycomb correlation
date

# Verify pods are terminating/gone
kubectl get pods -n istio-system -l app=istiod -w
```

**Step 3: Confirm control plane is down**

```bash
# Should show 0/0 ready
kubectl get deployment istiod -n istio-system

# No pods should exist
kubectl get pods -n istio-system -l app=istiod
# Should return "No resources found"
```

**Expected Behavior:**

- All Istiod pods terminate immediately
- NO automatic recovery (stays at 0 replicas)
- Control plane remains unavailable until manually restored
- Data plane continues handling traffic with cached config
- Perfect for testing extended outages (hours, not minutes)

**Duration:** As long as you want - manually controlled

---

#### 🔺 Bring Istiod Back Up (Restore)

**Step 1: Restore original replica count**

```bash
# Option A: If you saved the original count
kubectl scale deployment istiod -n istio-system --replicas=$ORIGINAL_REPLICAS

# Option B: Restore to default (usually 1 or 2)
kubectl scale deployment istiod -n istio-system --replicas=1

# Note timestamp for Honeycomb
date
```

**Step 2: Wait for pods to come back**

```bash
# Watch pods starting up
kubectl get pods -n istio-system -l app=istiod -w

# Wait for Ready status
kubectl wait --for=condition=Ready pod -n istio-system -l app=istiod --timeout=120s
```

**Step 3: Verify control plane is operational**

```bash
# Check deployment status (should show 1/1 or 2/2)
kubectl get deployment istiod -n istio-system

# Check pod health
kubectl get pods -n istio-system -l app=istiod

# Verify XDS connectivity (all sidecars reconnected)
istioctl proxy-status
# All proxies should show SYNCED
```

**Step 4: Test configuration delivery**

```bash
# Test sidecar injection works
kubectl rollout restart deployment/frontend -n otel-demo

# Check new pods have sidecars
kubectl get pods -n otel-demo -l app=frontend -o jsonpath='{.items[0].spec.containers[*].name}'
# Should see: frontend, istio-proxy
```

**Recovery Time:** 30-90 seconds after scaling back up

---

#### 📋 Quick Reference: Complete Outage Test

**Full command sequence:**

```bash
# 1. TAKE DOWN (and keep down)
ORIGINAL_REPLICAS=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.replicas}')
echo "Saving original replicas: $ORIGINAL_REPLICAS"
kubectl scale deployment istiod -n istio-system --replicas=0
date

# 2. OBSERVE (as long as you want)
# - Check Honeycomb for metrics impact
# - Verify services still work
# - Try deploying new services (should fail sidecar injection)
# - Monitor for how long data plane remains stable

# 3. BRING BACK UP
kubectl scale deployment istiod -n istio-system --replicas=$ORIGINAL_REPLICAS
date
kubectl wait --for=condition=Ready pod -n istio-system -l app=istiod --timeout=120s

# 4. VERIFY RESTORATION
kubectl get deployment istiod -n istio-system
istioctl proxy-status
```

---

#### 🎯 What This Test Proves

**Extended Control Plane Outage:**

- ✅ Data plane works for hours without control plane
- ✅ No service disruption during extended outage
- ✅ Configuration changes are blocked (as expected)
- ✅ Recovery is clean and complete

**Use Cases:**

- Test control plane maintenance windows
- Validate disaster recovery procedures
- Measure how long mesh can survive without control plane
- Test alert fatigue and escalation policies

**Risks:**

- ⚠️ No automatic recovery - you must manually scale back up
- ⚠️ Certificate rotation paused (issue if outage > cert TTL)
- ⚠️ New pods won't get sidecars until restored
- ⚠️ Configuration changes won't propagate

---

## 📊 What to Monitor in Honeycomb

### 1. Kubernetes Events (k8s-events dataset)

**Query: Detect Istiod Restarts**

```
WHERE namespace = "istio-system"
AND involved_object_name CONTAINS "istiod"
AND reason IN ("Killing", "Started", "Created", "Unhealthy")
ORDER BY timestamp DESC
```

**Expected Events:**

- `Killing`: Pod termination initiated
- `Created`: New pod created
- `Started`: Container started
- `Unhealthy`: Readiness probe failures during startup

---

### 2. Istio Metrics (opentelemetry-demo dataset)

**Query: Control Plane Availability**

```
WHERE job = "istio-mesh"
AND name = "pilot_xds_pushes"
RATE_SUM
```

- Should drop to **0** during outage
- Returns to normal after recovery

**Query: Envoy Proxy Connection Status**

```
WHERE job = "istio-mesh"
AND name = "pilot_xds_push_errors"
COUNT
GROUP BY type
```

- Spike in errors indicates sidecars can't reach control plane

---

### 3. Application Metrics

**Query: Service Request Rate (Should NOT Drop)**

```
WHERE job = "istio-mesh"
AND name = "istio_requests_total"
RATE_SUM
GROUP BY destination_workload
```

- **Critical:** Request rate should remain stable
- Data plane works independently of control plane

**Query: Error Rate (Should NOT Increase)**

```
WHERE job = "istio-mesh"
AND name = "istio_requests_total"
AND response_code >= 500
RATE_SUM
```

- No increase in errors during Istiod outage
- Validates data plane resilience

---

## 🧪 Step-by-Step Test Procedure

### Pre-Test Checklist

- [ ] Honeycomb dashboard open (Istio metrics + K8s events)
- [ ] Baseline traffic established (load generator running)
- [ ] All services healthy
- [ ] Take note of current metrics

### Test Execution

**Step 1: Establish Baseline (2 minutes)**

```bash
# Verify Istiod is healthy
kubectl get pods -n istio-system -l app=istiod

# Check baseline request rate
kubectl logs -n otel-demo deployment/otel-collector --tail=20 | grep istio_requests_total
```

**Step 2: Execute Chaos (Choose Method)**

```bash
# Method 1: Delete pods (recommended for first test)
kubectl delete pods -n istio-system -l app=istiod

# Note the timestamp for Honeycomb correlation
date
```

**Step 3: Observe Impact (5 minutes)**

Monitor in Honeycomb:

1. **K8s Events:** Watch for pod termination and creation
2. **Istio Control Plane Metrics:** XDS pushes drop to 0
3. **Application Metrics:** Request rate stays stable
4. **Error Rates:** Should not increase

**Step 4: Verify Recovery (2 minutes)**

```bash
# Wait for pods to be Running
kubectl get pods -n istio-system -l app=istiod -w

# Check readiness
kubectl wait --for=condition=Ready pod -n istio-system -l app=istiod --timeout=120s

# Verify control plane metrics return
kubectl logs -n otel-demo deployment/otel-collector --tail=20 | grep pilot_xds
```

**Step 5: Post-Test Validation**

```bash
# Test a new deployment (validates sidecar injection works)
kubectl rollout restart deployment/frontend -n otel-demo

# Verify sidecars are injected
kubectl get pods -n otel-demo -l app=frontend -o jsonpath='{.items[0].spec.containers[*].name}'
# Should see: frontend, istio-proxy
```

---

## ✅ Success Criteria

### During Outage (Control Plane Down)

- ✅ Application traffic continues without interruption
- ✅ No increase in 5xx errors
- ✅ Request rate remains stable
- ✅ Existing Envoy sidecars use cached configuration

### During Recovery (Control Plane Restarting)

- ✅ Istiod pods restart automatically
- ✅ Pods reach Ready state within 90 seconds
- ✅ Control plane metrics (pilot_xds_pushes) resume

### After Recovery (Control Plane Restored)

- ✅ New deployments receive sidecar injection
- ✅ Configuration changes (VirtualServices) propagate
- ✅ All Envoy sidecars reconnect to Istiod
- ✅ No lingering errors or connection issues

---

## ❌ Failure Modes to Watch For

### 1. Data Plane Traffic Disrupted

**Symptom:** Request rate drops or errors spike during Istiod outage

**Root Cause:** Envoy sidecars are misconfigured or not caching properly

**Fix:** Review Envoy bootstrap configuration and ensure proper connection timeouts

---

### 2. Istiod Pods Don't Restart

**Symptom:** Pods remain in Pending, CrashLoopBackOff, or Terminating state

**Root Cause:**

- Insufficient cluster resources
- ImagePullBackOff
- Webhook conflicts

**Debug:**

```bash
kubectl describe pod -n istio-system -l app=istiod
kubectl logs -n istio-system -l app=istiod --previous
```

---

### 3. Slow Recovery (> 2 minutes)

**Symptom:** Istiod takes > 2 minutes to become Ready

**Root Cause:**

- Large mesh with many sidecars
- Resource constraints (CPU/memory)
- Network issues

**Debug:**

```bash
# Check resource usage
kubectl top pod -n istio-system -l app=istiod

# Check events
kubectl get events -n istio-system --sort-by='.lastTimestamp'
```

---

### 4. Configuration Delivery Delayed

**Symptom:** VirtualServices or DestinationRules don't take effect after recovery

**Root Cause:** Envoy sidecars haven't reconnected yet

**Verify:**

```bash
# Check XDS sync status
istioctl proxy-status

# Should show all proxies as SYNCED
```

---

## 🔔 Recommended Alerts

### Alert 1: Istiod Pod Restarted

```
Dataset: k8s-events
WHERE namespace = "istio-system"
AND involved_object_name CONTAINS "istiod"
AND reason = "Killing"
COUNT > 0
```

**Threshold:** Any restart  
**Severity:** Medium  
**Action:** Investigate why Istiod restarted

---

### Alert 2: Istiod Unavailable

```
Dataset: k8s-events
WHERE namespace = "istio-system"
AND involved_object_kind = "Deployment"
AND involved_object_name = "istiod"
AND message CONTAINS "unavailable"
COUNT > 0
```

**Threshold:** > 0 for 1 minute  
**Severity:** High  
**Action:** Check pod status, ensure restart is progressing

---

### Alert 3: XDS Push Failures

```
Dataset: opentelemetry-demo
WHERE job = "istio-mesh"
AND name = "pilot_xds_push_errors"
RATE_SUM > 10
```

**Threshold:** > 10 errors/sec for 2 minutes  
**Severity:** High  
**Action:** Investigate control plane connectivity

---

## 🎓 Learning Outcomes

After this chaos test, you should understand:

1. **Control Plane vs Data Plane Separation**

   - Data plane (Envoy) is independent
   - Control plane only needed for configuration updates
   - Existing traffic flows don't require control plane

2. **Observability is Critical**

   - Early detection of Istiod issues prevents user impact
   - Kubernetes events provide first indication
   - Metrics confirm recovery completion

3. **Resilience Patterns**

   - Caching prevents cascading failures
   - Automatic restart policies enable self-healing
   - Graceful degradation allows continued operation

4. **Configuration Management**
   - New deployments impacted during outage
   - Existing deployments continue functioning
   - Configuration changes queue until recovery

---

## 🔗 Related Chaos Scenarios

- **Envoy Sidecar Crash:** Test individual service resilience
- **Network Partition:** Isolate control plane from data plane
- **Istiod Resource Starvation:** Limit CPU/memory to simulate overload
- **Certificate Expiration:** Test mTLS fallback behavior

---

## 📝 Notes

- **Safe for Production:** Yes, this is a realistic failure scenario
- **User Impact:** None expected (data plane continues)
- **Best Time to Run:** During normal traffic (not peak)
- **Frequency:** Monthly or after major Istio upgrades

---

## 📚 References

- [Istio Architecture: Control vs Data Plane](https://istio.io/latest/docs/ops/deployment/architecture/)
- [Pilot (Istiod) Troubleshooting](https://istio.io/latest/docs/ops/diagnostic-tools/pilot/)
- [Envoy Configuration Caching](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/dynamic_configuration)

---

**Last Updated:** 2025-11-03  
**Tested On:** Istio 1.20+, Kubernetes 1.28+  
**Status:** ✅ Ready for Testing
