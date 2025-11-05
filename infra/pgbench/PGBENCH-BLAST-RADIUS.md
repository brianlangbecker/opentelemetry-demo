# pgbench Beast Mode - Service Impact & Blast Radius

This document describes which services will be affected when running `pgbench.sh beast` and how to observe the cascading failures in Honeycomb.

---

## 🎯 Overview

**Only ONE service directly uses PostgreSQL:** `accounting`

But the blast radius affects **10+ services** through cascading failures via Kafka and service-to-service calls.

---

## 🔥 PRIMARY VICTIM (Direct PostgreSQL Impact)

### **accounting**
- **Type:** Direct PostgreSQL consumer
- **Database usage:** 1,246 queries per 30 minutes (INSERT/UPDATE orders)
- **Normal latency:** ~5ms P95
- **Technology:** .NET/C# with Entity Framework
- **Role:** Processes orders from Kafka, stores in PostgreSQL

#### What Breaks:
1. **Database queries slow down:** 5ms → 50ms → 500ms → timeout
2. **Entity Framework errors spike:** Duplicate key conflicts increase
3. **Kafka message backlog grows:** Can't process orders fast enough
4. **Service becomes unresponsive:** Eventually stops processing entirely
5. **PostgreSQL OOMKill:** After 15-20 minutes, database pod crashes

#### Honeycomb Queries to Monitor:

**Database Query Performance:**
```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: P50(duration_ms), P95(duration_ms), P99(duration_ms)
Breakdown: db.statement
Time: Last 30 minutes
```
**Expected:**
- T+0: P95 = 5ms
- T+5: P95 = 50ms
- T+10: P95 = 200ms
- T+15: P95 = 500ms+
- T+20: Timeouts/errors

**Order Processing Rate:**
```
Dataset: accounting
Calculate: COUNT
Time: Last 30 minutes (15-second intervals)
```
**Expected:** Massive drop as database slows

**Entity Framework Errors:**
```
Dataset: accounting
WHERE exception.message exists
Calculate: COUNT
Breakdown: exception.type
```
**Expected:** "IdentityMap duplicate key" errors spike

---

## 💥 SECONDARY VICTIMS (Kafka Dependency)

### **checkout**
- **Type:** Order creator → sends to Kafka → accounting consumes
- **Current traffic:** 71 downstream service calls per 30 minutes
- **Role:** Orchestrates order placement (cart → payment → shipping → email)

#### What Breaks:
1. **Kafka backlog builds up:** accounting can't keep up
2. **Order completion delays:** Users wait longer for confirmations
3. **Timeout errors:** Frontend receives 504 Gateway Timeout
4. **Cascading failures:** Payment, shipping, email services back up

#### Honeycomb Queries:

**Error Rate:**
```
Dataset: checkout
Calculate: COUNT
Breakdown: http.status_code
Time: Last 30 minutes
```
**Expected:** 200 (success) → 500 (errors) → 504 (timeout)

**Downstream Service Health:**
```
Dataset: checkout
WHERE rpc.service exists
Calculate: P95(duration_ms), COUNT
Breakdown: rpc.service
```
**Expected:** All downstream calls slow down

**Service Map:**
```
checkout → currency (71 calls)
checkout → product-catalog (47 calls)
checkout → cart (44 calls)
checkout → shipping (40 calls)
checkout → payment (20 calls)
checkout → email (24 calls)
```

---

## 😰 TERTIARY VICTIMS (User-Facing)

### **frontend**
- **Type:** User-facing web application
- **Current traffic:** 366 requests per 30 minutes from load-generator
- **Role:** Serves web UI, calls backend services

#### What Breaks:
1. **Slow checkout page loads:** Users experience delays
2. **Failed order submissions:** "Order failed" errors displayed
3. **User-visible timeouts:** White screen or error messages
4. **Cascading latency:** All pages slow down due to service mesh overhead

#### Honeycomb Queries:

**Checkout Endpoint Performance:**
```
Dataset: frontend
WHERE rpc.service = "oteldemo.CheckoutService"
Calculate: P95(duration_ms), COUNT
Time: Last 30 minutes
```
**Expected:** <100ms → 500ms → 1000ms+ → timeout

**HTTP Error Rate:**
```
Dataset: frontend
Calculate: COUNT
Breakdown: http.status_code, http.route
```
**Expected:** /cart/checkout shows high error rate

**User Experience:**
```
Dataset: frontend
WHERE http.route = "/cart/checkout"
Calculate: P50(duration_ms), P95(duration_ms), P99(duration_ms)
```
**Expected:** P95 goes from 100ms to 5000ms+

---

### **load-generator**
- **Type:** Synthetic traffic generator
- **Current traffic:** 366 requests per 30 minutes to frontend
- **Role:** Simulates user behavior

#### What Breaks:
1. **Increased error rate in synthetic tests**
2. **Request timeouts**
3. **Failed checkout scenarios**

#### Honeycomb Query:

```
Dataset: load-generator
Calculate: COUNT
Breakdown: http.status_code
```
**Expected:** Success rate drops from 100% to 50%

---

## 🤕 DOWNSTREAM COLLATERAL DAMAGE

These services don't break but experience slowdowns:

| Service | Called By | Calls/30min | Impact |
|---------|-----------|-------------|--------|
| **cart** | checkout | 44 | Slower cart operations |
| **product-catalog** | checkout, frontend, recommendation | 423 | Catalog queries slow |
| **currency** | checkout | 71 | Currency conversions delay |
| **shipping** | checkout | 40 | Shipping calculations slow |
| **payment** | checkout | 20 | Payment processing delays |
| **email** | checkout | 24 | Order confirmation emails delayed |
| **quote** | shipping | 20 | Shipping quote delays |
| **recommendation** | frontend | 34 | Product recommendations lag |
| **ad** | frontend | 34 | Ad serving delays |

---

## 📊 Expected Timeline

### Minute-by-Minute Breakdown:

**0-2 minutes: Initialization**
- PostgreSQL: Initializing 20M rows (pgbench_accounts table)
- CPU: 5-10%
- Memory: 200Mi
- Services: All normal

**2-5 minutes: Load Test Starts**
- PostgreSQL: 100 concurrent connections attempting 5M transactions
- CPU: 20-40%
- Memory: 300Mi
- accounting: Queries starting to slow (P95: 5ms → 20ms)
- Services: Normal

**5-10 minutes: Degradation Begins**
- PostgreSQL: CPU 60-80%, Memory 400-500Mi
- accounting: **P95 latency: 50ms → 200ms**
- checkout: Timeouts starting to appear
- frontend: Checkout page slowing down
- Kafka: Message backlog building

**10-15 minutes: Critical State**
- PostgreSQL: CPU 90-100%, Memory 600-800Mi
- accounting: **P95 latency: 500ms+**, Entity Framework errors spiking
- checkout: **Error rate 20-30%**
- frontend: **Failed order submissions**
- Kafka: Large backlog (1000+ messages)

**15-20 minutes: Failure Cascade**
- PostgreSQL: CPU 100%, Memory 900Mi-1Gi
- accounting: **Processing nearly stopped**
- checkout: **Error rate 50%+**
- frontend: **Most checkouts failing**
- load-generator: **High synthetic test failure rate**

**20-30 minutes: System Collapse**
- PostgreSQL: **OOMKilled** (memory exhaustion)
- accounting: **Down** (can't connect to database)
- checkout: **Down** (accounting unavailable)
- frontend: **Checkout completely broken**
- Pod restart initiated

**30+ minutes: Recovery**
- PostgreSQL: Pod restarting
- accounting: Reconnecting to database
- checkout: Gradually recovering
- frontend: Checkout functionality restored
- Kafka: Processing backlog

---

## 🔍 Critical Honeycomb Queries

### Query 1: PostgreSQL Resource Saturation
```
Dataset: Metrics
WHERE service.name = "postgresql"
Calculate: AVG(system.cpu.utilization), AVG(system.memory.usage)
Time: Last 30 minutes (1-minute intervals)
```

### Query 2: Accounting Database Performance
```
Dataset: accounting
WHERE db.system = "postgresql"
Calculate: P95(duration_ms), COUNT
Breakdown: db.statement
Orders: P95(duration_ms) DESC
```

### Query 3: Checkout Service Health
```
Dataset: checkout
Calculate: COUNT
Breakdown: http.status_code
Time: Last 30 minutes (30-second intervals)
```

### Query 4: Frontend User Impact
```
Dataset: frontend
WHERE rpc.service = "oteldemo.CheckoutService"
Calculate: P95(duration_ms), COUNT
Time: Last 30 minutes
```

### Query 5: PostgreSQL Pod Events
```
Dataset: k8s-events
WHERE k8s.pod.name contains "postgresql"
  AND (k8s.container.last_terminated.reason = "OOMKilled"
       OR k8s.event.reason = "Killing"
       OR k8s.event.reason = "BackOff")
Calculate: COUNT
Breakdown: k8s.event.reason, k8s.container.last_terminated.reason
```

### Query 6: Service Mesh Traffic Impact
```
Dataset: frontend
Calculate: P95(duration_ms)
Breakdown: rpc.service
Orders: P95(duration_ms) DESC
Time: Last 30 minutes
```

### Query 7: Kafka Consumer Lag (via accounting)
```
Dataset: accounting
Calculate: COUNT
Time: Last 30 minutes (15-second intervals)
```
**Expected:** Huge spike at start (backlog), then drop to near zero (can't process)

---

## 🎯 Service Dependency Graph

```
PostgreSQL (OOMKill at T+20min)
    ↓
accounting (Database queries timeout)
    ↑ (Kafka consumer)
Kafka (Message backlog grows)
    ↑ (Kafka producer)
checkout (Timeouts, errors)
    ↑ (gRPC calls)
frontend (Failed checkouts)
    ↑ (HTTP)
load-generator (Synthetic test failures)
    ↑ (Simulated traffic)
Users (Order placement fails)
```

**Downstream from checkout:**
- cart
- product-catalog
- currency
- shipping
- payment
- email
- quote (via shipping)

---

## 📈 Key Performance Indicators (KPIs)

### Database Health
- **Normal:** P95 < 10ms, CPU < 20%, Memory < 300Mi
- **Degraded:** P95 50-200ms, CPU 60-80%, Memory 500-700Mi
- **Critical:** P95 > 500ms, CPU > 90%, Memory > 800Mi
- **Failed:** OOMKilled, Pod restart

### Service Health
- **accounting:** Normal = 1,000+ queries/min, Failed = <100 queries/min
- **checkout:** Normal = 100% success rate, Failed = <50% success rate
- **frontend:** Normal = P95 <100ms, Failed = P95 >1000ms

### User Impact
- **Order success rate:** Normal = 100%, Failed = <50%
- **Checkout page load:** Normal = <500ms, Failed = >5000ms or timeout
- **Error messages:** Normal = 0%, Failed = 50%+

---

## 🚨 Expected Errors

### accounting Service Logs:
```
System.InvalidOperationException: The instance of entity type 'OrderEntity'
cannot be tracked because another instance with the same key value for {'Id'}
is already being tracked.
```

### PostgreSQL Errors:
```
FATAL: sorry, too many clients already
```

### Kubernetes Events:
```
Reason: OOMKilled
Message: Container killed due to memory pressure
```

### Frontend User Experience:
```
HTTP 504 Gateway Timeout
Error: Failed to place order. Please try again.
```

---

## 🔧 Post-Mortem Analysis

After beast mode completes, analyze:

1. **Time to first failure:** How long until errors appeared?
2. **Blast radius:** Which services were affected?
3. **Recovery time:** How long to restore full service?
4. **Error propagation:** How did failures cascade?
5. **Resource limits:** Were pod resource limits appropriate?

### Honeycomb Queries for Post-Mortem:

**Failure Timeline:**
```
Dataset: accounting, checkout, frontend
Calculate: COUNT
Breakdown: http.status_code or exception.type
Time: Beast mode duration + 10 minutes
```

**Resource Usage at Failure:**
```
Dataset: Metrics
WHERE service.name = "postgresql"
Calculate: MAX(system.memory.usage), MAX(system.cpu.utilization)
Time: Beast mode duration
```

**Service Recovery:**
```
Dataset: k8s-events
WHERE k8s.pod.name contains "postgresql"
Calculate: COUNT
Breakdown: k8s.event.reason
Time: Beast mode duration + 30 minutes
```

---

## 📝 Notes

- **PostgreSQL has max_connections = 100**, so beast mode with 100 clients may hit connection limits
- **Accounting uses Entity Framework**, which has its own connection pooling
- **Normal PostgreSQL pod resources:** 300Mi memory, CPU varies
- **OOMKill threshold:** ~1Gi memory usage
- **Typical TPS under load:** 1,000-5,000 transactions/second
- **Beast mode target:** 20,000-50,000+ TPS (will cause failure)

---

## 🎬 Ready to Run?

Use this document to:
1. **Predict** what will break and when
2. **Monitor** services in real-time using Honeycomb
3. **Demonstrate** cascading failures and blast radius
4. **Analyze** observability data after the test

**Start command:**
```bash
cd infra/pgbench/
./pgbench.sh beast
```

**Monitor in Honeycomb:**
- Open accounting, checkout, and frontend datasets
- Watch for latency spikes and error rates
- Track PostgreSQL pod resource usage in Metrics dataset
- Observe OOMKill event in k8s-events dataset

---

**Good luck! May your observability be strong and your blast radius well-documented.** 🚀💥
