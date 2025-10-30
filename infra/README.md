# OpenTelemetry Demo - Infrastructure Setup

This directory contains Helm values and Kubernetes resources for deploying the OpenTelemetry Demo.

---

## 📁 **Files Overview**

| **File**                         | **Purpose**                               | **When to Use**                          |
| -------------------------------- | ----------------------------------------- | ---------------------------------------- |
| `otel-demo-values.yaml`          | Main Helm values (Honeycomb config)       | ✅ Every install                         |
| `otel-demo-values-aws.yaml`      | AWS-specific Helm values                  | AWS deployments                          |
| `postgres-persistent-setup.yaml` | PVC + ConfigMap for PostgreSQL            | For IOPS demos with persistence          |
| `postgres-patch.yaml`            | Patch to attach PVC to PostgreSQL         | After Helm install (if using PVC)        |
| `install-with-persistence.sh`    | **One-command installer**                 | 🚀 **Easiest way** to enable persistence |
| `seed-150k.sql`                  | Pre-seed 150K orders into DB              | Optional: instant IOPS demo              |
| `verify-postgres.md`             | PostgreSQL verification & troubleshooting | When setting up or debugging PostgreSQL  |
| `SETUP-NOTES.md`                 | Detailed setup documentation              | Troubleshooting                          |

---

## 🚀 **Quick Start**

### **Option 1: Standard Install (Ephemeral PostgreSQL)**

```bash
# PostgreSQL data will be lost on pod restart
helm install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml \
  --create-namespace
```

### **Option 2: Install with Persistent PostgreSQL (Recommended for IOPS Demos)**

```bash
# One command - sets up PVC and patches PostgreSQL automatically
./install-with-persistence.sh otel-demo-values.yaml
```

**What it does:**

1. ✅ Creates namespace
2. ✅ Creates 2Gi PersistentVolumeClaim
3. ✅ Installs Helm chart
4. ✅ Patches PostgreSQL to use persistent storage

### **Option 3: Manual Install with Persistence**

```bash
# Step 1: Create namespace and PVC
kubectl create namespace otel-demo
kubectl apply -f postgres-persistent-setup.yaml

# Step 2: Install Helm chart
helm install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml

# Step 3: Patch PostgreSQL deployment
kubectl patch deployment postgresql -n otel-demo \
  --patch-file postgres-patch.yaml
```

---

## ❓ **Why is the PVC Not in `otel-demo-values.yaml`?**

**Short Answer:** The OpenTelemetry Demo Helm chart doesn't support PVC configuration for PostgreSQL through `values.yaml`.

**Detailed Explanation:**

- The demo is designed for **ephemeral testing**, not production persistence
- The `postgresql` component in the Helm chart only exposes:
  - `env` (environment variables) ✅
  - `resources` (CPU/memory limits) ✅
  - `replicas`, `service.port` ✅
  - ❌ **No** `volumes`, `volumeMounts`, or `persistence` options

**Solution:**

- PVCs must be created as **separate Kubernetes resources**
- Then **patched** onto the PostgreSQL deployment after Helm install
- Use our `install-with-persistence.sh` script for automated setup

---

## 🔄 **Common Operations**

### **Upgrade Helm Release**

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml
```

### **Uninstall (Keeps PVC if created separately)**

```bash
helm uninstall otel-demo -n otel-demo

# To also delete PVC and data
kubectl delete pvc postgresql-data -n otel-demo
```

### **Port Forwarding**

```bash
# Frontend
kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080

# Jaeger UI
kubectl -n otel-demo port-forward svc/jaeger-query 16686:16686

# Load Generator (Locust)
kubectl -n otel-demo port-forward svc/load-generator 8089:8089
```

---

## 🎭 **For Chaos Demos**

See documentation in the chaos-scenarios directory:

- **[postgres-chaos-iops-demo.md](../chaos-scenarios/postgres-chaos-iops-demo.md)** - Cache pressure chaos demo
- **[postgres-disk-iops-pressure.md](../chaos-scenarios/postgres-disk-iops-pressure.md)** - Organic IOPS growth
- **[postgres-seed-for-iops.md](../chaos-scenarios/postgres-seed-for-iops.md)** - Database pre-seeding

---

## 📚 **Additional Resources**

- [SETUP-NOTES.md](SETUP-NOTES.md) - Comprehensive setup guide
- [ChaosTesting.md](../ChaosTesting.md) - All chaos scenarios
- [chaos-scenarios/](../chaos-scenarios/) - Individual scenario guides
