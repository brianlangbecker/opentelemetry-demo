# Post-Install Patches for OpenTelemetry Demo

This document describes critical patches that must be applied after a fresh Helm install.

## Critical: Product Catalog Database Timeouts

**WHY THIS IS CRITICAL:** The product-catalog service contains database query timeout fixes (30-second timeouts on all queries) that prevent indefinite hangs when PostgreSQL table locks occur. Without this patch, the service can hang indefinitely waiting for locked database queries.

### Changes Made:
- Added 30-second statement-level timeouts to all database queries:
  - `listProductsFromDB()` - Lists all products
  - `getProductFromDB()` - Gets single product by ID
  - `searchProductsFromDB()` - Searches products by query
- Added `db.statement.timeout: "30s"` span attribute for observability
- Fixed Dockerfile to run binary directly (removed problematic entrypoint script)

### How to Apply:

**Option 1: Run the build script (RECOMMENDED)**
```bash
cd opentelemetry-demo
./infra/build-and-deploy-product-catalog.sh
```

The script will:
1. Detect your cluster architecture (arm64/amd64)
2. Build the product-catalog image for the correct platform
3. Push to your ECR repository
4. Deploy to the cluster
5. Wait for rollout to complete
6. Verify the deployment

**Option 2: Manual steps**
```bash
# 1. Get cluster architecture
NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
echo "Building for: ${NODE_ARCH}"

# 2. Build image
docker build \
  --platform linux/${NODE_ARCH} \
  -f src/product-catalog/Dockerfile \
  -t YOUR_ECR_REPO/product-catalog:db-timeouts \
  .

# 3. Push to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin YOUR_ECR_REPO
docker push YOUR_ECR_REPO/product-catalog:db-timeouts

# 4. Deploy
kubectl set image deployment/product-catalog \
  -n otel-demo \
  product-catalog=YOUR_ECR_REPO/product-catalog:db-timeouts

# 5. Wait for rollout
kubectl rollout status deployment/product-catalog -n otel-demo
```

## Checkout Memory Limits

**STATUS:** ✅ Already applied to Helm values

The checkout service memory limits have been updated in both Helm values files:
- `infra/otel-demo-values.yaml`
- `infra/otel-demo-values-aws.yaml`

Settings:
```yaml
checkout:
  resources:
    limits:
      memory: 100Mi
    requests:
      memory: 50Mi
```

No additional patches needed - this will be applied automatically on Helm install/upgrade.

## Collector Configuration (Node Crash Detection)

**STATUS:** ✅ Already applied to Helm values

The OpenTelemetry Collector configuration has been updated in both Helm values files to detect node crashes:

Features added:
- Node object watching in k8sobjects receiver
- Node condition extraction (Ready, MemoryPressure, DiskPressure)
- Node status reporting to Honeycomb k8s-events dataset

No additional patches needed - this will be applied automatically on Helm install/upgrade.

## PostgreSQL Sidecar Collector

**STATUS:** ✅ Already in source

The PostgreSQL sidecar collector configuration is stored in:
- `infra/postgres-otel-configmap.yaml`
- `infra/postgres-otel-sidecar-patch.yaml`

These are applied as part of the infrastructure setup and don't require post-install patches.

## Verification

After applying patches, verify:

```bash
# 1. Check product-catalog is running with new image
kubectl get pods -n otel-demo -l app.kubernetes.io/name=product-catalog
kubectl describe deployment product-catalog -n otel-demo | grep Image:

# 2. Check logs show database connection with timeout support
kubectl logs -n otel-demo -l app.kubernetes.io/name=product-catalog -c product-catalog --tail=20

# 3. Check checkout memory limits
kubectl get deployment checkout -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# Should show: 100Mi

# 4. Verify node watching is enabled
kubectl get configmap -n otel-demo otel-collector -o yaml | grep -A 10 "k8sobjects:"
# Should show nodes in the objects list
```

## Troubleshooting

### Product-catalog build fails
- **Error: "exec format error"** - Wrong architecture. Make sure you're building for the same architecture as your cluster nodes.
- **Error: Docker not running** - Start Docker Desktop before running the script.
- **Error: ECR login failed** - Check your AWS credentials and profile.

### Product-catalog deployment fails
- Check pod logs: `kubectl logs -n otel-demo -l app.kubernetes.io/name=product-catalog -c product-catalog`
- Check pod events: `kubectl describe pod -n otel-demo -l app.kubernetes.io/name=product-catalog`
- Verify image exists in ECR: `aws ecr describe-images --repository-name otel-demo/product-catalog --region us-east-1`

### Database timeouts not working
- Verify the new image is deployed: `kubectl describe deployment product-catalog -n otel-demo | grep Image:`
- Check traces in Honeycomb for `db.statement.timeout` attribute
- Run a long query and verify it times out at 30 seconds
