#!/bin/bash
# Script to verify load-generator configuration and health after disabling browser traffic

set -e

NAMESPACE="otel-demo"
COMPONENT="load-generator"

echo "=========================================="
echo "Load Generator Verification Script"
echo "=========================================="
echo ""

# Check if kubectl is authenticated
echo "🔍 Checking cluster access..."
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to cluster. Please authenticate first:"
    echo "   aws sso login --profile <your-profile>"
    exit 1
fi
echo "✅ Cluster access confirmed"
echo ""

# Check pod status
echo "🔍 Checking load-generator pod status..."
PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=$COMPONENT -o json)
POD_COUNT=$(echo $PODS | jq -r '.items | length')

if [ "$POD_COUNT" -eq 0 ]; then
    echo "❌ No load-generator pods found!"
    exit 1
fi

echo "Found $POD_COUNT load-generator pod(s)"
echo ""

# Check each pod
for i in $(seq 0 $((POD_COUNT - 1))); do
    POD_NAME=$(echo $PODS | jq -r ".items[$i].metadata.name")
    POD_STATUS=$(echo $PODS | jq -r ".items[$i].status.phase")
    RESTART_COUNT=$(echo $PODS | jq -r ".items[$i].status.containerStatuses[0].restartCount")
    READY=$(echo $PODS | jq -r ".items[$i].status.containerStatuses[0].ready")
    
    echo "Pod $((i+1)): $POD_NAME"
    echo "  Status: $POD_STATUS"
    echo "  Ready: $READY"
    echo "  Restarts: $RESTART_COUNT"
    
    if [ "$POD_STATUS" != "Running" ]; then
        echo "  ⚠️  Pod is not running!"
    elif [ "$READY" != "true" ]; then
        echo "  ⚠️  Pod is not ready!"
    else
        echo "  ✅ Pod is healthy"
    fi
    echo ""
done

# Check browser traffic configuration
echo "🔍 Checking LOCUST_BROWSER_TRAFFIC_ENABLED environment variable..."
FIRST_POD=$(echo $PODS | jq -r '.items[0].metadata.name')

BROWSER_TRAFFIC=$(kubectl get pod $FIRST_POD -n $NAMESPACE -o json | \
    jq -r '.spec.containers[0].env[] | select(.name=="LOCUST_BROWSER_TRAFFIC_ENABLED") | .value')

if [ "$BROWSER_TRAFFIC" = "false" ]; then
    echo "✅ Browser traffic is DISABLED (value: $BROWSER_TRAFFIC)"
elif [ "$BROWSER_TRAFFIC" = "true" ]; then
    echo "❌ Browser traffic is still ENABLED (value: $BROWSER_TRAFFIC)"
    echo "   Did you run helm upgrade with the updated values?"
elif [ -z "$BROWSER_TRAFFIC" ]; then
    echo "⚠️  LOCUST_BROWSER_TRAFFIC_ENABLED not found (defaults to enabled)"
else
    echo "⚠️  Unexpected value: $BROWSER_TRAFFIC"
fi
echo ""

# Check memory configuration
echo "🔍 Checking memory limits..."
MEMORY_LIMIT=$(kubectl get pod $FIRST_POD -n $NAMESPACE -o json | \
    jq -r '.spec.containers[0].resources.limits.memory')

echo "Memory limit: $MEMORY_LIMIT"
if [[ "$MEMORY_LIMIT" == *"Gi"* ]]; then
    echo "✅ Memory limit looks good for high user count"
else
    echo "⚠️  Memory limit may be too low for high user count"
fi
echo ""

# Check for recent OOMKilled events
echo "🔍 Checking for recent OOMKilled events..."
OOMKILLED=$(kubectl get events -n $NAMESPACE --field-selector involvedObject.kind=Pod \
    --sort-by='.lastTimestamp' | grep -i "OOMKilled" | grep "$COMPONENT" | tail -5)

if [ -z "$OOMKILLED" ]; then
    echo "✅ No recent OOMKilled events found"
else
    echo "⚠️  Recent OOMKilled events found:"
    echo "$OOMKILLED"
fi
echo ""

# Check current user count in Locust
echo "🔍 Checking current Locust configuration..."
LOCUST_USERS=$(kubectl get pod $FIRST_POD -n $NAMESPACE -o json | \
    jq -r '.spec.containers[0].env[] | select(.name=="LOCUST_USERS") | .value')

echo "Configured users (autostart): $LOCUST_USERS"
echo ""

# Get Locust UI access info
echo "=========================================="
echo "📊 Locust UI Access"
echo "=========================================="
echo ""
echo "To access the Locust UI, port-forward:"
echo ""
echo "  kubectl port-forward -n $NAMESPACE svc/$COMPONENT 8089:8089"
echo ""
echo "Then open: http://localhost:8089"
echo ""
echo "You can now safely test with 50+ users!"
echo ""

# Check pod logs for errors
echo "🔍 Checking recent logs for errors..."
RECENT_ERRORS=$(kubectl logs -n $NAMESPACE $FIRST_POD --tail=50 | grep -i "error\|exception\|failed" | head -10 || true)

if [ -z "$RECENT_ERRORS" ]; then
    echo "✅ No recent errors in logs"
else
    echo "⚠️  Recent errors found:"
    echo "$RECENT_ERRORS"
fi
echo ""

# Memory usage check
echo "🔍 Checking current memory usage..."
MEMORY_USAGE=$(kubectl top pod $FIRST_POD -n $NAMESPACE 2>/dev/null | tail -1 | awk '{print $3}' || echo "metrics-server not available")

if [ "$MEMORY_USAGE" != "metrics-server not available" ]; then
    echo "Current memory usage: $MEMORY_USAGE"
    echo "Memory limit: $MEMORY_LIMIT"
else
    echo "⚠️  Cannot check memory usage (metrics-server may not be installed)"
fi
echo ""

echo "=========================================="
echo "✅ Verification Complete!"
echo "=========================================="

