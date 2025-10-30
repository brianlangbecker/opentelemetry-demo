# Why COUNT() Shows Too Many Restarts

## 🎯 **TL;DR: Use MAX(), Not COUNT()!**

```
❌ WRONG:
WHERE: k8s.container.restart_count > 0
VISUALIZE: COUNT()

✅ CORRECT:
WHERE: k8s.container.restart_count > 0
VISUALIZE: MAX(k8s.container.restart_count)
```

---

## 🔍 **What's Happening:**

### **The Problem:**

When you run:

```
WHERE: k8s.container.restart_count > 0
VISUALIZE: COUNT()
```

**You're counting HOW MANY EVENTS Honeycomb received, NOT how many restarts happened!**

---

## 📊 **Example: Grafana with 1 Restart**

### **Kubernetes Reality:**

```
Grafana restarted ONCE at 11:35 AM
restart_count = 1
```

### **What k8sobjects Receiver Does:**

```
11:35:09 AM: Grafana starts → Send event to Honeycomb (restart_count=1)
11:35:24 AM: OOMKilled → Send event to Honeycomb (restart_count=1)
11:35:25 AM: Container restarted → Send event to Honeycomb (restart_count=1)
11:35:30 AM: Pod becomes ready → Send event to Honeycomb (restart_count=1)
11:35:45 AM: Health check passes → Send event to Honeycomb (restart_count=1)
11:36:00 AM: Status update → Send event to Honeycomb (restart_count=1)
11:37:00 AM: Status update → Send event to Honeycomb (restart_count=1)
... continues every time pod status changes ...
12:44:00 AM: Status update → Send event to Honeycomb (restart_count=1)
```

**Result:** 100+ Honeycomb events, ALL showing `restart_count=1`

---

### **What COUNT() Shows:**

```
COUNT() = 100+ events
```

**This is the number of times the field was SENT, not the restart count!**

### **What MAX() Shows:**

```
MAX(k8s.container.restart_count) = 1
```

**This is the ACTUAL number of restarts!** ✅

---

## 🎓 **Why This Happens:**

The `k8sobjects` receiver operates in **"watch" mode**:

```yaml
k8sobjects:
  objects:
    - name: pods
      mode: watch  ← Continuously watches for changes
```

**Watch mode sends an event to Honeycomb EVERY TIME:**

- Pod status changes
- Container state changes
- Health checks run
- Readiness probes execute
- Liveness probes execute
- Any field in the Pod object updates

**Each event includes the CURRENT value of `restart_count`**

---

## ✅ **The Correct Queries:**

### **Query 1: See Actual Restart Counts**

```
DATASET: k8s-events
WHERE:
  k8s.container.restart_count > 0
  AND k8s.object.kind = 'Pod'
TIME RANGE: Last 1 hour

VISUALIZE: MAX(k8s.container.restart_count)  ← MAX, not COUNT!
GROUP BY: k8s.pod.name, k8s.container.name
ORDER BY: MAX(k8s.container.restart_count) DESC
```

**Result for Grafana:**

```
grafana-xxx | grafana | 1
```

---

### **Query 2: Latest Restart Count (Real-Time)**

```
DATASET: k8s-events
WHERE:
  k8s.container.restart_count > 0
  AND k8s.object.kind = 'Pod'
TIME RANGE: Last 15 minutes

VISUALIZE: LATEST(k8s.container.restart_count)  ← Even better!
GROUP BY: k8s.pod.name, k8s.container.name
```

**This shows the CURRENT restart count**

---

### **Query 3: How Many Times Did Pod Status Update? (Debugging)**

```
DATASET: k8s-events
WHERE:
  k8s.pod.name CONTAINS 'grafana'
  AND k8s.object.kind = 'Pod'
TIME RANGE: Last 1 hour

VISUALIZE: COUNT()  ← Now COUNT makes sense
GROUP BY: k8s.container.restart_count
```

**Result:**

```
restart_count=0: 50 events
restart_count=1: 200 events  ← Pod updated 200 times with restart_count=1
```

This shows **how chatty** the k8sobjects receiver is!

---

## 📋 **Field Behavior Comparison:**

| **Field**                              | **How It Works**   | **Correct Aggregation**    |
| -------------------------------------- | ------------------ | -------------------------- |
| `k8s.container.restart_count`          | Cumulative counter | `MAX()` or `LATEST()`      |
| `k8s.event.reason = 'Started'`         | Discrete event     | `COUNT()` ✅               |
| `k8s.container.last_terminated.reason` | State field        | `COUNT()` of unique events |
| `k8s.pod.phase`                        | State field        | `LATEST()`                 |

---

## 🎯 **Correct Dashboard Panels:**

### **Panel: Current Restart Counts**

```
WHERE: k8s.container.restart_count > 0
VISUALIZE: LATEST(k8s.container.restart_count)
GROUP BY: k8s.pod.name
TIME: Last 15 minutes
```

### **Panel: Restart Timeline (Show When Restarts Happened)**

```
WHERE: k8s.event.reason = 'Started'
VISUALIZE: COUNT()
GROUP BY: k8s.pod.name, time(5m)
```

### **Panel: How Many Events per Pod (Debugging)**

```
WHERE: k8s.object.kind = 'Pod'
VISUALIZE: COUNT()
GROUP BY: k8s.pod.name
TIME: Last 1 hour
```

---

## 🚨 **Common Mistakes:**

### **Mistake 1: Using COUNT() with restart_count**

```
❌ COUNT(k8s.container.restart_count > 0)
Returns: Number of events (useless)

✅ MAX(k8s.container.restart_count)
Returns: Actual restart count (useful!)
```

### **Mistake 2: Not filtering by object kind**

```
❌ WHERE: k8s.container.restart_count > 0
Includes: Pod updates AND Event objects (mixed data)

✅ WHERE: k8s.container.restart_count > 0 AND k8s.object.kind = 'Pod'
Includes: Only Pod status updates
```

### **Mistake 3: Using too long a time range**

```
❌ TIME: Last 24 hours
Returns: Thousands of pod updates

✅ TIME: Last 15 minutes (for LATEST)
Returns: Most recent status only
```

---

## 🔧 **Troubleshooting:**

### **"I see 500 events for Grafana but it only restarted once!"**

**This is NORMAL!** Run this query:

```
WHERE: k8s.pod.name CONTAINS 'grafana'
VISUALIZE: MAX(k8s.container.restart_count)
```

You'll see: `1` (the actual restart count)

---

### **"Why are there so many events?"**

The k8sobjects receiver sends updates **continuously**:

- Every ~30 seconds for status updates
- Every time a health check runs
- Every time readiness changes
- Every time a field updates

**For a pod running 1 hour:** ~120 events minimum (2 per minute)

---

## ✅ **Summary:**

| **What You Want**         | **Query**                                  |
| ------------------------- | ------------------------------------------ |
| Actual restart count      | `MAX(k8s.container.restart_count)`         |
| Current state             | `LATEST(k8s.container.restart_count)`      |
| When did restarts happen? | `k8s.event.reason = 'Started'` + `COUNT()` |
| How many events received? | `COUNT()` (for debugging only)             |

---

## 🎉 **The Answer to Your Question:**

**You're seeing a "bunch of counts" because:**

1. Grafana restarted **1 time**
2. k8sobjects sent **100+ events** (all showing restart_count=1)
3. `COUNT()` counts events (100+), not restarts (1)

**Solution:** Use `MAX(k8s.container.restart_count)` instead of `COUNT()`

---

## 🔍 **Try This Now:**

```
DATASET: k8s-events
WHERE:
  k8s.pod.name CONTAINS 'grafana'
  AND k8s.container.restart_count > 0

SIDE BY SIDE:
Panel 1: COUNT() → Shows 100+
Panel 2: MAX(k8s.container.restart_count) → Shows 1

Time range: Last 1 hour
```

**See the difference!** 🎯
