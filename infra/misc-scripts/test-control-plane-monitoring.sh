#!/bin/bash

# Test Control Plane Monitoring in Honeycomb
# This script scales istiod down and up to test monitoring

set -e

echo "======================================"
echo "Control Plane Monitoring Test"
echo "======================================"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Save original replica count
echo -e "${YELLOW}Step 1: Check current state${NC}"
ORIGINAL_REPLICAS=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.replicas}')
echo "✓ Istiod currently has $ORIGINAL_REPLICAS replica(s)"
echo ""

# Honeycomb query to run
echo -e "${YELLOW}Step 2: Run this query in Honeycomb to establish baseline:${NC}"
echo ""
echo "Dataset: opentelemetry-demo"
echo "WHERE job = \"istio-mesh\""
echo "AND name = \"pilot_xds_pushes\""
echo "RATE_SUM"
echo "VISUALIZE OVER LAST 15 MINUTES"
echo ""
echo "Expected: Rate > 0 (control plane active)"
echo ""
read -p "Press ENTER when you have the query open in Honeycomb..."

# Scale down
echo ""
echo -e "${RED}Step 3: Scaling DOWN istiod (control plane outage)${NC}"
TIMESTAMP_DOWN=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "Timestamp: $TIMESTAMP_DOWN"
kubectl scale deployment istiod -n istio-system --replicas=0
echo "✓ Istiod scaled to 0"
echo ""

echo -e "${YELLOW}Waiting 30 seconds for metrics to reflect the change...${NC}"
sleep 30

echo ""
echo -e "${YELLOW}Step 4: Refresh your Honeycomb query${NC}"
echo "Expected: Rate dropped to 0 at ~$TIMESTAMP_DOWN"
echo ""
read -p "Do you see the drop to 0? Press ENTER to continue..."

# Scale up
echo ""
echo -e "${GREEN}Step 5: Scaling UP istiod (restore control plane)${NC}"
TIMESTAMP_UP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "Timestamp: $TIMESTAMP_UP"
kubectl scale deployment istiod -n istio-system --replicas=$ORIGINAL_REPLICAS
echo "✓ Istiod scaled back to $ORIGINAL_REPLICAS"
echo ""

echo -e "${YELLOW}Waiting for istiod to be ready...${NC}"
kubectl wait --for=condition=Ready pod -n istio-system -l app=istiod --timeout=120s
echo "✓ Istiod is ready"
echo ""

echo -e "${YELLOW}Waiting 30 seconds for metrics to reflect recovery...${NC}"
sleep 30

echo ""
echo -e "${YELLOW}Step 6: Refresh your Honeycomb query one more time${NC}"
echo "Expected: Rate returned to > 0 at ~$TIMESTAMP_UP"
echo ""

echo -e "${GREEN}======================================"
echo "Test Complete!"
echo "======================================${NC}"
echo ""
echo "You should see in Honeycomb:"
echo "  1. Normal rate (before $TIMESTAMP_DOWN)"
echo "  2. Drop to 0 (at $TIMESTAMP_DOWN)"
echo "  3. Return to normal (at $TIMESTAMP_UP)"
echo ""
echo "This proves your control plane monitoring works! ✅"
echo ""
echo "Next: Set up alerts in Honeycomb for when pilot_xds_pushes = 0"

