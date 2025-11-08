#!/bin/bash
# One-command install script for OpenTelemetry Demo with PostgreSQL persistence
#
# Usage:
#   ./install-with-persistence.sh [values-file]
#
# Example:
#   ./install-with-persistence.sh otel-demo-values.yaml./install-with-persistence.sh otel-demo-values-aws.yaml
#   

set -e

VALUES_FILE="${1:-otel-demo-values.yaml}"
NAMESPACE="otel-demo"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🚀 Installing OpenTelemetry Demo with PostgreSQL persistence + OTel sidecar"
echo "   Using values: $VALUES_FILE"
echo ""

# Step 1: Create namespace
echo "📦 Step 1/6: Creating namespace..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Apply PVC and ConfigMap
echo "💾 Step 2/6: Creating PersistentVolumeClaim for PostgreSQL..."
kubectl apply -f "$SCRIPT_DIR/postgres-persistent-setup.yaml"

# Step 3: Apply OTel Collector sidecar ConfigMap
echo "📋 Step 3/6: Creating OTel Collector sidecar ConfigMap..."
kubectl apply -f "$SCRIPT_DIR/postgres-otel-configmap.yaml"

# Step 4: Install Helm chart
echo "⎈ Step 4/6: Installing Helm chart..."
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  -n $NAMESPACE \
  --values "$SCRIPT_DIR/$VALUES_FILE" \
  --wait \
  --timeout 5m

# Step 5: Patch PostgreSQL deployment to use PVC
echo "🔧 Step 5/6: Patching PostgreSQL deployment to use persistent storage..."
kubectl patch deployment postgresql -n $NAMESPACE \
  --patch-file "$SCRIPT_DIR/postgres-patch.yaml"

# Wait for PostgreSQL to stabilize after PVC patch
echo "⏳ Waiting for PostgreSQL to stabilize after PVC patch..."
sleep 10
kubectl rollout status deployment/postgresql -n $NAMESPACE --timeout=2m

# Step 6: Add OTel Collector sidecar to PostgreSQL
echo "📊 Step 6/6: Adding OTel Collector sidecar to PostgreSQL pod..."
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

kubectl patch deployment postgresql -n $NAMESPACE --type='json' -p="$(cat /tmp/add-otel-sidecar.json)"

# Wait for final rollout with sidecar
echo "⏳ Waiting for PostgreSQL pod to start with OTel sidecar..."
kubectl rollout status deployment/postgresql -n $NAMESPACE --timeout=3m

# Verify sidecar is running
echo ""
echo "🔍 Verifying sidecar deployment..."
CONTAINERS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].spec.containers[*].name}')
echo "   Containers in PostgreSQL pod: $CONTAINERS"

if [[ "$CONTAINERS" == *"otel-collector"* ]]; then
  echo "   ✅ OTel Collector sidecar is present"
  
  # Check sidecar logs
  echo ""
  echo "📋 Checking sidecar logs (last 5 lines)..."
  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=postgresql -c otel-collector --tail=5 || echo "   (Logs not available yet, sidecar may still be starting)"
else
  echo "   ⚠️  OTel Collector sidecar not found in pod"
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "📊 Access the demo:"
echo "   Frontend: kubectl port-forward -n $NAMESPACE svc/frontend-proxy 8080:8080"
echo "   Jaeger:   kubectl port-forward -n $NAMESPACE svc/jaeger-query 16686:16686"
echo "   Locust:   kubectl port-forward -n $NAMESPACE svc/load-generator 8089:8089"
echo ""
echo "💾 PostgreSQL features:"
echo "   ✅ Persistent storage (survives pod restarts)"
echo "   ✅ OTel Collector sidecar (comprehensive metrics)"
echo "   ✅ Filesystem metrics segregated by volume"
echo ""
echo "📈 View PostgreSQL metrics in Honeycomb:"
echo "   WHERE service.name = \"postgresql-sidecar\""
echo ""

