#!/bin/bash
# Build and deploy product-catalog with database timeout fixes
# This script MUST be run after any Helm install/upgrade to apply critical database timeout changes

set -e

echo "======================================"
echo "Building product-catalog with DB timeouts"
echo "======================================"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile product-us)
AWS_REGION="us-east-1"
ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/otel-demo/product-catalog"
IMAGE_TAG="db-timeouts-$(date +%Y%m%d-%H%M%S)"

echo "AWS Account: ${AWS_ACCOUNT_ID}"
echo "ECR Repo: ${ECR_REPO}"
echo "Image Tag: ${IMAGE_TAG}"
echo ""

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker is not running. Please start Docker Desktop."
    exit 1
fi

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region ${AWS_REGION} --profile product-us | \
    docker login --username AWS --password-stdin ${ECR_REPO}

# Get node architecture from cluster
echo "Detecting cluster architecture..."
NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
echo "Cluster architecture: ${NODE_ARCH}"

# Map to Docker platform
if [ "$NODE_ARCH" = "arm64" ]; then
    PLATFORM="linux/arm64"
elif [ "$NODE_ARCH" = "amd64" ]; then
    PLATFORM="linux/amd64"
else
    echo "ERROR: Unknown architecture: ${NODE_ARCH}"
    exit 1
fi

echo "Building for platform: ${PLATFORM}"
echo ""

# Build the image
echo "Building Docker image..."
docker build \
    --platform ${PLATFORM} \
    -f src/product-catalog/Dockerfile \
    -t ${ECR_REPO}:${IMAGE_TAG} \
    -t ${ECR_REPO}:latest \
    .

if [ $? -ne 0 ]; then
    echo "ERROR: Docker build failed"
    exit 1
fi

# Push the image
echo ""
echo "Pushing image to ECR..."
docker push ${ECR_REPO}:${IMAGE_TAG}
docker push ${ECR_REPO}:latest

if [ $? -ne 0 ]; then
    echo "ERROR: Docker push failed"
    exit 1
fi

# Update deployment
echo ""
echo "Updating product-catalog deployment..."
kubectl set image deployment/product-catalog \
    -n otel-demo \
    product-catalog=${ECR_REPO}:${IMAGE_TAG}

# Set imagePullPolicy to Always
kubectl patch deployment product-catalog \
    -n otel-demo \
    --type='json' \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Always"}]'

# Wait for rollout
echo ""
echo "Waiting for rollout to complete..."
kubectl rollout status deployment/product-catalog -n otel-demo --timeout=180s

if [ $? -ne 0 ]; then
    echo "ERROR: Rollout failed or timed out"
    echo "Check pod status: kubectl get pods -n otel-demo -l app.kubernetes.io/name=product-catalog"
    echo "Check logs: kubectl logs -n otel-demo -l app.kubernetes.io/name=product-catalog -c product-catalog"
    exit 1
fi

# Verify deployment
echo ""
echo "Verifying deployment..."
POD_NAME=$(kubectl get pods -n otel-demo -l app.kubernetes.io/name=product-catalog -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n otel-demo ${POD_NAME} -c product-catalog --tail=10

echo ""
echo "======================================"
echo "SUCCESS: product-catalog deployed with DB timeouts"
echo "Image: ${ECR_REPO}:${IMAGE_TAG}"
echo "Pod: ${POD_NAME}"
echo "======================================"
echo ""
echo "IMPORTANT: This image includes 30-second statement timeouts on all database queries."
echo "Queries exceeding 30 seconds will be cancelled with context deadline exceeded error."
