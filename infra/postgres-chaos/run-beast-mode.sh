#!/bin/bash
# Helper script to run beast-mode-chaos.sql against PostgreSQL pod

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
  echo "ERROR: No PostgreSQL pod found in otel-demo namespace"
  exit 1
fi

echo "Found PostgreSQL pod: $POD"
echo ""
echo "Starting BEAST MODE CHAOS..."
echo "This will run for ~30 minutes (900 cycles × 2s)"
echo "Press Ctrl+C to stop early"
echo ""
echo "IMPORTANT: Script does NOT auto-cleanup!"
echo "After completion, run: kubectl exec -n otel-demo \$POD -- psql -U root -d otel -c 'VACUUM FULL ANALYZE orderitem;'"
echo ""

# Copy the script to the pod and run it
kubectl cp "$SCRIPT_DIR/beast-mode-chaos.sql" otel-demo/$POD:/tmp/beast-mode-chaos.sql
kubectl exec -n otel-demo $POD -- psql -U root -d otel -f /tmp/beast-mode-chaos.sql

echo ""
echo "BEAST MODE CHAOS completed!"
