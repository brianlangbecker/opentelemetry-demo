# How to Track Pod Restarts in Honeycomb

## 🎯 Quick Answer: 3 Ways to Find Restarts

---

## **Method 1: Use Restart Count (Easiest!)**

```
DATASET: k8s-events
WHERE:
  k8s.container.restart_count > 0
  AND k8s.object.kind = 'Pod'
TIME RANGE: Last 1 hour

VISUALIZE: MAX(k8s.container.restart_count)
GROUP BY: k8s.pod.name, k8s.container.name
ORDER BY: MAX(k8s.container.restart_count) DESC
```

**What this shows:**

- All pods with restarts
- How many times each restarted
- Updates in real-time as pods restart

**Best for:** Quick health check

---

## **Method 2: Use OOMKilled for Memory Crashes**

```
DATASET: k8s-events
WHERE: k8s.container.last_terminated.reason = 'OOMKilled'
TIME RANGE: Last 24 hours

VISUALIZE: COUNT()
GROUP BY: k8s.pod.name, k8s.container.name, time(1h)
```

**What this shows:**

- Every OOMKilled event
- Which pods ran out of memory
- Timeline of crashes

**Best for:** Memory pressure investigation

---

## **Method 3: Use "Started" Events (All Restarts)**

```
DATASET: k8s-events
WHERE:
  k8s.event.reason = 'Started'
  AND k8s.object.kind = 'Event'
TIME RANGE: Last 1 hour

VISUALIZE: COUNT()
GROUP BY: k8s.pod.name
HAVING: COUNT() > 1
```

**What this shows:**

- Pods that started MORE than once
- If COUNT = 1: Normal startup
- If COUNT > 1: Pod restarted!

**Best for:** Detecting any restart (not just crashes)

---

## 🔍 **Why can't I find `k8s.container.last_terminated.finished_at`?**

### **Issue:**

This field only appears in Honeycomb when:

1. ✅ A pod has actually terminated
2. ✅ The `k8sobjects` receiver captures the Pod update
3. ✅ The transform processor extracts the field

### **Debugging:**

**Step 1: Check if field exists at all**

```
DATASET: k8s-events
BREAKDOWN BY: *
LIMIT: 1
```

Look for fields starting with `k8s.container.last_terminated.*`

**Step 2: Check if Pod objects are coming through**

```
DATASET: k8s-events
WHERE: k8s.object.kind = 'Pod'
TIME RANGE: Last 15 minutes
VISUALIZE: COUNT()
```

Should see events if Pods are being watched

**Step 3: Look for terminated containers**

```
DATASET: k8s-events
WHERE:
  k8s.object.kind = 'Pod'
  AND body.object.status.containerStatuses EXISTS
BREAKDOWN BY: body.object.status.containerStatuses[0].lastState.terminated.reason
```

This searches the raw body field

---

## 📊 **Complete Restart Detection Dashboard**

Create a board with these panels:

### **Panel 1: Pods with Restarts (Current State)**

```
WHERE:
  k8s.container.restart_count > 0
  AND k8s.object.kind = 'Pod'
TIME: Last 15 minutes

VISUALIZE: MAX(k8s.container.restart_count)
GROUP BY: k8s.pod.name
ORDER BY: MAX(k8s.container.restart_count) DESC

GRAPH: Bar chart
```

### **Panel 2: Restart Timeline**

```
WHERE: k8s.event.reason = 'Started'
TIME: Last 1 hour

VISUALIZE: COUNT()
GROUP BY: k8s.pod.name, time(5m)

GRAPH: Heatmap
```

### **Panel 3: OOMKilled Events**

```
WHERE: k8s.container.last_terminated.reason = 'OOMKilled'
TIME: Last 24 hours

VISUALIZE: COUNT()
GROUP BY: k8s.pod.name, time(1h)

GRAPH: Line chart
```

### **Panel 4: Crash Reasons**

```
WHERE: k8s.container.last_terminated.reason EXISTS
TIME: Last 24 hours

VISUALIZE: COUNT()
GROUP BY: k8s.container.last_terminated.reason

GRAPH: Pie chart
```

---

## 🚨 **Alerts for Restarts**

### **Alert 1: Pod Restarted**

```
WHERE: k8s.event.reason = 'Started'
TRIGGER: COUNT() >= 2 per pod in last 10 minutes
MESSAGE: "Pod {{ k8s.pod.name }} restarted!"
```

### **Alert 2: High Restart Count**

```
WHERE: k8s.container.restart_count > 3
TRIGGER: MAX >= 3 in last 15 minutes
MESSAGE: "Pod {{ k8s.pod.name }} has {{ MAX(k8s.container.restart_count) }} restarts!"
```

### **Alert 3: OOMKilled**

```
WHERE: k8s.container.last_terminated.reason = 'OOMKilled'
TRIGGER: COUNT() >= 1 in last 5 minutes
MESSAGE: "Pod {{ k8s.pod.name }} OOMKilled!"
```

---

## 🎓 **Understanding the Fields**

### **Available Fields for Restart Tracking:**

| **Field**                                 | **What It Means**   | **When Available**        |
| ----------------------------------------- | ------------------- | ------------------------- |
| `k8s.container.restart_count`             | Total restart count | Always (for running pods) |
| `k8s.event.reason = 'Started'`            | Pod startup event   | Every start/restart       |
| `k8s.container.last_terminated.reason`    | Why last crash      | After first crash         |
| `k8s.container.last_terminated.exit_code` | Exit code           | After first crash         |
| `k8s.container.state`                     | Current state       | Always                    |
| `k8s.pod.phase`                           | Pod lifecycle       | Always                    |

---

## 🔧 **Troubleshooting Checklist**

**Problem:** Can't find `k8s.container.last_terminated.finished_at`

**Checklist:**

- [ ] Check if collector config has `transform/k8s_events` processor
- [ ] Verify collector has been upgraded (`helm upgrade` ran)
- [ ] Check if any pods have ACTUALLY crashed/restarted since config update
- [ ] Try searching for the field in "Fields" tab of Honeycomb query builder
- [ ] Use `k8s.container.restart_count` instead (easier!)

**Quick Test:**

```
DATASET: k8s-events
TIME: Last 2 hours
BREAKDOWN BY: *
LIMIT: 100
```

Manually scroll through all available fields to see what's there.

---

## ✅ **Recommended: Use These Working Queries**

### **For General Restarts:**

```
k8s.container.restart_count > 0
```

### **For OOMKilled:**

```
k8s.container.last_terminated.reason = 'OOMKilled'
```

### **For Any Crash:**

```
k8s.container.last_terminated.reason EXISTS
```

### **For Restart Timeline:**

```
k8s.event.reason = 'Started'
AND COUNT() grouped by pod name
```

---

## 📝 **Summary**

**Three guaranteed ways to track restarts:**

1. **Restart Count** → `k8s.container.restart_count > 0` (Real-time)
2. **OOMKilled** → `k8s.container.last_terminated.reason = 'OOMKilled'` (Memory crashes)
3. **Started Events** → `k8s.event.reason = 'Started'` + `COUNT() > 1` (All restarts)

**Don't worry about `finished_at` - the restart count and reason are what you actually need!** 🎯
