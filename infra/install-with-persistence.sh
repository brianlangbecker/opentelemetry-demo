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

echo "🚀 Installing OpenTelemetry Demo with PostgreSQL persistence + OTel sidecar + logging"
echo "   Using values: $VALUES_FILE"
echo ""

# Step 1: Create namespace
echo "📦 Step 1/8: Creating namespace..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Apply PVC and ConfigMap
echo "💾 Step 2/8: Creating PersistentVolumeClaim for PostgreSQL..."
kubectl apply -f "$SCRIPT_DIR/postgres-persistent-setup.yaml"

# Step 3: Apply OTel Collector sidecar ConfigMap
echo "📋 Step 3/8: Creating OTel Collector sidecar ConfigMap..."
kubectl apply -f "$SCRIPT_DIR/postgres-otel-configmap.yaml"

# Step 4: Install Helm chart
echo "⎈ Step 4/8: Installing Helm chart..."
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  -n $NAMESPACE \
  --values "$SCRIPT_DIR/$VALUES_FILE" \
  --wait \
  --timeout 5m

# Step 5: Patch PostgreSQL deployment to use PVC
echo "🔧 Step 5/8: Patching PostgreSQL deployment to use persistent storage..."
kubectl patch deployment postgresql -n $NAMESPACE \
  --patch-file "$SCRIPT_DIR/postgres-patch.yaml"

# Wait for PostgreSQL to stabilize after PVC patch
echo "⏳ Waiting for PostgreSQL to stabilize after PVC patch..."
sleep 10
kubectl rollout status deployment/postgresql -n $NAMESPACE --timeout=2m

# Step 6: Add OTel Collector sidecar to PostgreSQL (with log volume)
echo "📊 Step 6/8: Adding OTel Collector sidecar to PostgreSQL pod..."
kubectl patch deployment postgresql -n $NAMESPACE \
  --patch-file "$SCRIPT_DIR/postgres-otel-sidecar-patch.yaml"

# Wait for sidecar to be added
echo "⏳ Waiting for PostgreSQL pod to restart with OTel sidecar..."
kubectl rollout status deployment/postgresql -n $NAMESPACE --timeout=3m

# Step 7: Enable PostgreSQL logging
echo "📋 Step 7/8: Enabling PostgreSQL logging (table locks, slow queries)..."
kubectl apply -f "$SCRIPT_DIR/postgres-logging-setup-job.yaml"

# Wait for job to complete
echo "⏳ Waiting for logging setup job to complete..."
kubectl wait --for=condition=complete --timeout=60s job/postgres-logging-setup -n $NAMESPACE || echo "   ⚠️  Job may still be running"

# Step 8: Restart PostgreSQL to activate logging_collector
echo "🔄 Step 8/8: Restarting PostgreSQL to activate logging..."
kubectl rollout restart deployment/postgresql -n $NAMESPACE
kubectl rollout status deployment/postgresql -n $NAMESPACE --timeout=3m

# Verify everything is running
echo ""
echo "🔍 Verifying deployment..."
CONTAINERS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].spec.containers[*].name}')
echo "   Containers in PostgreSQL pod: $CONTAINERS"

if [[ "$CONTAINERS" == *"otel-collector"* ]]; then
  echo "   ✅ OTel Collector sidecar is present"
else
  echo "   ⚠️  OTel Collector sidecar not found in pod"
fi

# Check sidecar and logging
echo ""
echo "📋 Checking OTel collector logs (last 10 lines)..."
kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=postgresql -c otel-collector --tail=10 | grep -E "(filelog|Started watching)" || echo "   (Collector starting up...)"

# Verify logging is enabled
echo ""
echo "🔍 Verifying PostgreSQL logging configuration..."
kubectl exec -n $NAMESPACE deployment/postgresql -c postgresql -- \
  psql -U root -d otel -tAc "SHOW logging_collector;" 2>/dev/null | grep -q "on" && \
  echo "   ✅ PostgreSQL logging is enabled" || \
  echo "   ⚠️  PostgreSQL logging may still be activating"

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
echo "   ✅ PostgreSQL logging enabled (table locks, slow queries)"
echo "   ✅ Filesystem metrics segregated by volume"
echo ""
echo "📈 View PostgreSQL data in Honeycomb:"
echo "   # Metrics"
echo "   WHERE service.name = \"postgresql-sidecar\" AND postgresql.* EXISTS"
echo ""
echo "   # Logs (table locks, slow queries)"
echo "   WHERE service.name = \"postgresql-sidecar\" AND body EXISTS"
echo "   WHERE body CONTAINS \"still waiting for\"  # Table locks"
echo "   WHERE body CONTAINS \"duration:\"          # Slow queries"
echo ""
echo "📚 Documentation:"
echo "   PostgreSQL Logging: infra/POSTGRESQL-LOGGING.md"
echo ""

