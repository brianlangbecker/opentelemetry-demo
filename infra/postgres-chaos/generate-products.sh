#!/bin/bash
# Generate 1000 Products for OpenTelemetry Demo Product Catalog
# This script adds astronomy/telescope themed products to the database

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-otel-demo}"
POD_SELECTOR="${POD_SELECTOR:-deployment/postgresql}"
DB_USER="${DB_USER:-root}"
DB_NAME="${DB_NAME:-otel}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}=========================================="
echo "Product Generator for OpenTelemetry Demo"
echo -e "==========================================${NC}"

# Find PostgreSQL pod
echo -e "${GREEN}Finding PostgreSQL pod in namespace: ${NAMESPACE}${NC}"
POD=$(kubectl get pod -n ${NAMESPACE} -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD" ]; then
    echo -e "${RED}ERROR: PostgreSQL pod not found in namespace ${NAMESPACE}${NC}"
    exit 1
fi

echo -e "${GREEN}Using PostgreSQL pod: ${POD}${NC}"

# Check current product count
echo -e "${YELLOW}Checking current product count...${NC}"
CURRENT_COUNT=$(kubectl exec -n ${NAMESPACE} ${POD} -- psql -U ${DB_USER} ${DB_NAME} -t -c "SELECT count(*) FROM products;" | tr -d ' ')
echo -e "${BLUE}Current products: ${CURRENT_COUNT}${NC}"

# Copy SQL script to pod
echo -e "${YELLOW}Copying SQL script to pod...${NC}"
kubectl cp ${SCRIPT_DIR}/generate-products.sql ${NAMESPACE}/${POD}:/tmp/generate-products.sql

# Execute SQL script
echo -e "${YELLOW}Generating 1000 new products...${NC}"
kubectl exec -n ${NAMESPACE} ${POD} -- psql -U ${DB_USER} ${DB_NAME} -f /tmp/generate-products.sql

# Verify new count
echo -e "${YELLOW}Verifying product count...${NC}"
NEW_COUNT=$(kubectl exec -n ${NAMESPACE} ${POD} -- psql -U ${DB_USER} ${DB_NAME} -t -c "SELECT count(*) FROM products;" | tr -d ' ')
echo -e "${BLUE}New product count: ${NEW_COUNT}${NC}"
echo -e "${GREEN}Products added: $((NEW_COUNT - CURRENT_COUNT))${NC}"

# Show some sample products
echo -e "${YELLOW}Sample of newly created products:${NC}"
kubectl exec -n ${NAMESPACE} ${POD} -- psql -U ${DB_USER} ${DB_NAME} -c "SELECT id, name, price_units, categories FROM products ORDER BY created_at DESC LIMIT 5;"

# Clean up temp file
kubectl exec -n ${NAMESPACE} ${POD} -- rm -f /tmp/generate-products.sql

echo -e "${GREEN}=========================================="
echo "Product generation complete!"
echo -e "==========================================${NC}"
