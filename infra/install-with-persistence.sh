#!/bin/bash
# One-command install script for OpenTelemetry Demo with PostgreSQL persistence
#
# Usage:
#   ./install-with-persistence.sh [values-file]
#
# Example:
#   ./install-with-persistence.sh otel-demo-values.yaml
#   ./install-with-persistence.sh otel-demo-values-aws.yaml

set -e

VALUES_FILE="${1:-otel-demo-values.yaml}"
NAMESPACE="otel-demo"

echo "🚀 Installing OpenTelemetry Demo with PostgreSQL persistence"
echo "   Using values: $VALUES_FILE"
echo ""

# Step 1: Create namespace
echo "📦 Step 1/4: Creating namespace..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Apply PVC and ConfigMap
echo "💾 Step 2/4: Creating PersistentVolumeClaim for PostgreSQL..."
kubectl apply -f postgres-persistent-setup.yaml

# Step 3: Install Helm chart
echo "⎈ Step 3/4: Installing Helm chart..."
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  -n $NAMESPACE \
  --values $VALUES_FILE \
  --wait \
  --timeout 5m

# Step 4: Patch PostgreSQL deployment to use PVC
echo "🔧 Step 4/4: Patching PostgreSQL deployment to use persistent storage..."
kubectl patch deployment postgresql -n $NAMESPACE \
  --patch-file postgres-patch.yaml

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl rollout status deployment/postgresql -n $NAMESPACE --timeout=2m

echo ""
echo "✅ Installation complete!"
echo ""
echo "📊 Access the demo:"
echo "   Frontend: kubectl port-forward -n $NAMESPACE svc/frontend-proxy 8080:8080"
echo "   Jaeger:   kubectl port-forward -n $NAMESPACE svc/jaeger-query 16686:16686"
echo "   Locust:   kubectl port-forward -n $NAMESPACE svc/load-generator 8089:8089"
echo ""
echo "💾 PostgreSQL data is persistent and will survive pod restarts"
echo ""

