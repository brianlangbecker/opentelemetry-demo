# OpenTelemetry Demo - Install From Scratch

**Complete installation guide with PostgreSQL persistence and OTel Collector sidecar**

---

## Prerequisites

- Kubernetes cluster (EKS, GKE, AKS, or local like k3d/minikube)
- `kubectl` configured and connected to your cluster
- `helm` CLI installed (version 3.x)
- OpenTelemetry Demo Helm repository added:
  ```bash
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
  helm repo update
  ```

---

## Option 1: One-Command Installation (Recommended)

Use the automated installation script that handles everything:

```bash
cd infra
./install-with-persistence.sh otel-demo-values-aws.yaml
```

This script will:
1. ✅ Create the `otel-demo` namespace
2. ✅ Create PersistentVolumeClaim for PostgreSQL (2 GB)
3. ✅ Create OTel Collector sidecar ConfigMap
4. ✅ Install the Helm chart
5. ✅ Patch PostgreSQL to use persistent storage
6. ✅ Add OTel Collector sidecar to PostgreSQL pod
7. ✅ Verify everything is running

**For local Kubernetes (Docker Desktop, k3d, minikube):**
```bash
./install-with-persistence.sh otel-demo-values.yaml
```

---

## Option 2: Manual Step-by-Step Installation

### Step 1: Create Namespace

```bash
kubectl create namespace otel-demo
```

### Step 2: Create PersistentVolumeClaim

```bash
kubectl apply -f postgres-persistent-setup.yaml
```

**What this does:**
- Creates a 2 GB PersistentVolumeClaim named `postgresql-data`
- Creates a ConfigMap `postgres-config` with PostgreSQL settings

**Verify:**
```bash
kubectl get pvc -n otel-demo
# Should show: postgresql-data   Bound   ...   2Gi
```

### Step 3: Create OTel Collector Sidecar ConfigMap

```bash
kubectl apply -f postgres-otel-configmap.yaml
```

**What this does:**
- Creates ConfigMap `postgres-otel-config` with comprehensive metrics configuration
- Enables 17+ PostgreSQL metrics (connections, cache, WAL, indexes, tables)
- Enables filesystem metrics (segregated by volume)
- Enables disk I/O, memory, and CPU metrics

**Verify:**
```bash
kubectl get configmap -n otel-demo postgres-otel-config
```

### Step 4: Install Helm Chart

**For AWS/Cloud:**
```bash
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values-aws.yaml \
  --wait \
  --timeout 5m
```

**For Local Kubernetes:**
```bash
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml \
  --wait \
  --timeout 5m
```

**Wait for all pods to be ready:**
```bash
kubectl get pods -n otel-demo
```

### Step 5: Patch PostgreSQL for Persistent Storage

```bash
kubectl patch deployment postgresql -n otel-demo \
  --patch-file postgres-patch.yaml
```

**What this does:**
- Mounts the `postgresql-data` PVC to `/var/lib/postgresql/data`
- Sets PostgreSQL shared_buffers and cache size
- Configures resource limits

**Wait for rollout:**
```bash
kubectl rollout status deployment/postgresql -n otel-demo --timeout=2m
```

### Step 6: Add OTel Collector Sidecar

**Option A: Using the patch file (if your cluster supports strategic merge):**
```bash
kubectl patch deployment postgresql -n otel-demo \
  --patch-file postgres-otel-sidecar-patch.yaml
```

**Option B: Using JSON patch (works everywhere):**
```bash
cat > /tmp/add-otel-sidecar.json <<'EOF'
[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/-",
    "value": {
      "name": "otel-collector",
      "image": "otel/opentelemetry-collector-contrib:0.135.0",
      "args": ["--config=/conf/otelcol-config.yaml"],
      "env": [
        {
          "name": "POSTGRES_PASSWORD",
          "value": "otel"
        },
        {
          "name": "OTEL_COLLECTOR_HOST",
          "value": "otel-collector"
        },
        {
          "name": "OTEL_COLLECTOR_PORT_GRPC",
          "value": "4317"
        }
      ],
      "resources": {
        "limits": {
          "memory": "256Mi",
          "cpu": "200m"
        },
        "requests": {
          "memory": "128Mi",
          "cpu": "100m"
        }
      },
      "volumeMounts": [
        {
          "name": "otel-collector-config",
          "mountPath": "/conf",
          "readOnly": true
        },
        {
          "name": "postgresql-data",
          "mountPath": "/var/lib/postgresql/data",
          "readOnly": true
        }
      ]
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "otel-collector-config",
      "configMap": {
        "name": "postgres-otel-config",
        "items": [
          {
            "key": "otelcol-config.yaml",
            "path": "otelcol-config.yaml"
          }
        ]
      }
    }
  }
]
EOF

kubectl patch deployment postgresql -n otel-demo --type='json' -p="$(cat /tmp/add-otel-sidecar.json)"
```

**Wait for rollout:**
```bash
kubectl rollout status deployment/postgresql -n otel-demo --timeout=3m
```

---

## Verification

### Check All Pods are Running

```bash
kubectl get pods -n otel-demo
```

**Expected output:** All pods should be in `Running` state.

### Verify PostgreSQL Pod has 3 Containers

```bash
kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].spec.containers[*].name}'
```

**Expected output:** `postgresql otel-collector`

(Plus `istio-proxy` if Istio is enabled)

### Check OTel Collector Sidecar Logs

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=postgresql -c otel-collector --tail=20
```

**Look for:**
- ✅ `info	Metrics	{...}` - Metrics are being collected
- ✅ `resource metrics: 7, metrics: 17, data points: 300+` - Metrics count
- ❌ No errors about connection refused or config issues

### Check PostgreSQL Data Persistence

```bash
kubectl exec -n otel-demo -it deployment/postgresql -- psql -U root -d otel -c "SELECT COUNT(*) FROM products;"
```

**Should return:** Number of products in the database (e.g., 1500+)

### Verify Metrics in Honeycomb

**Query for sidecar metrics:**
```
WHERE service.name = "postgresql-sidecar"
  AND postgresql.db_size EXISTS
GROUP BY postgresql.database.name
VISUALIZE MAX(postgresql.db_size)
TIME RANGE: Last 10 minutes
```

**Expected results:**
- `otel` database: ~700 MB
- `postgres` database: ~7.3 MB

**Query for filesystem metrics:**
```
WHERE service.name = "postgresql-sidecar"
  AND system.filesystem.usage EXISTS
GROUP BY mountpoint, state
VISUALIZE SUM(system.filesystem.usage)
```

**Expected results:**
- `/var/lib/postgresql/data` with `used` and `free` states
- Shows actual disk usage on PVC

---

## Access the Demo

### Frontend (Web Store)
```bash
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
```
Open: http://localhost:8080

### Jaeger (Distributed Tracing)
```bash
kubectl port-forward -n otel-demo svc/jaeger-query 16686:16686
```
Open: http://localhost:16686

### Locust (Load Generator)
```bash
kubectl port-forward -n otel-demo svc/load-generator 8089:8089
```
Open: http://localhost:8089

### Grafana (Dashboards)
```bash
kubectl port-forward -n otel-demo svc/grafana 3000:3000
```
Open: http://localhost:3000

---

## Troubleshooting

### PostgreSQL Pod Not Starting

**Check events:**
```bash
kubectl describe pod -n otel-demo -l app.kubernetes.io/name=postgresql
```

**Common issues:**
- PVC not bound: Check `kubectl get pvc -n otel-demo`
- ConfigMap missing: Check `kubectl get configmap -n otel-demo postgres-otel-config`
- Resource limits: Check node capacity with `kubectl describe nodes`

### OTel Collector Sidecar Crashing

**Check logs:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=postgresql -c otel-collector
```

**Common issues:**
- `connection refused` to PostgreSQL: PostgreSQL may still be starting, wait 30s
- `connection refused` to otel-collector: Check service exists `kubectl get svc -n otel-demo otel-collector`
- Config errors: Verify ConfigMap applied correctly

### No Metrics in Honeycomb

**1. Check sidecar is exporting:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=postgresql -c otel-collector | grep "Metrics"
```

**2. Check main collector is receiving:**
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector | grep postgresql-sidecar
```

**3. Verify main collector is sending to Honeycomb:**
Check your `otel-demo-values.yaml` for correct Honeycomb API key and endpoint.

### Data Not Persisting

**Check PVC is mounted:**
```bash
kubectl get pod -n otel-demo -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].spec.volumes[?(@.name=="postgresql-data")]}'
```

**Should show:** `persistentVolumeClaim` (not `emptyDir`)

**Check volume mount:**
```bash
kubectl exec -n otel-demo deployment/postgresql -- df -h | grep pgdata
```

---

## Uninstall

### Option 1: Keep Data (Remove Demo but Keep PVC)

```bash
helm uninstall otel-demo -n otel-demo
kubectl delete configmap postgres-otel-config -n otel-demo
# PVC remains for future use
```

### Option 2: Complete Removal (Including Data)

```bash
helm uninstall otel-demo -n otel-demo
kubectl delete namespace otel-demo
# This deletes PVC and all data
```

---

## Next Steps

1. **Run Chaos Tests:** See `postgres-chaos/README.md` for connection exhaustion, IOPS tests
2. **Explore Metrics:** See `postgres-chaos/docs/POSTGRESQL-SIDECAR-METRICS.md` for full metric list
3. **Build Dashboards:** Use Honeycomb queries to create operational dashboards
4. **Stress Test:** Use `postgres-chaos-scenarios.sh` to test blast radius

---

## Files Reference

| File | Purpose |
|------|---------|
| `install-with-persistence.sh` | One-command installation script |
| `postgres-persistent-setup.yaml` | PVC and PostgreSQL ConfigMap |
| `postgres-patch.yaml` | Patches PostgreSQL to use PVC |
| `postgres-otel-configmap.yaml` | OTel Collector sidecar configuration |
| `postgres-otel-sidecar-patch.yaml` | Adds sidecar to PostgreSQL pod |
| `otel-demo-values.yaml` | Helm values for local Kubernetes |
| `otel-demo-values-aws.yaml` | Helm values for AWS/cloud |

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ PostgreSQL Pod (Deployment)                                │
│                                                             │
│  ┌─────────────────────┐    ┌────────────────────────────┐│
│  │ PostgreSQL          │    │ OTel Collector (Sidecar)   ││
│  │ Container           │    │                            ││
│  │                     │    │ Receivers:                 ││
│  │ 127.0.0.1:5432 ─────┼────┤ • postgresql (localhost)   ││
│  │                     │    │ • hostmetrics (pod-local)  ││
│  │                     │    │                            ││
│  │ Volumes:            │    │ Exporters:                 ││
│  │ • PVC (2GB)         │    │ • otlp → otel-collector    ││
│  │   /var/lib/postgres │    │                            ││
│  └─────────────────────┘    └────────────────────────────┘│
└────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │ Main OTel Collector   │
                              │ (Cluster Service)     │
                              │                       │
                              │ → Honeycomb/Prometheus│
                              └───────────────────────┘
```

---

**Questions?** Check the [PostgreSQL Sidecar Metrics Guide](postgres-chaos/docs/POSTGRESQL-SIDECAR-METRICS.md)

