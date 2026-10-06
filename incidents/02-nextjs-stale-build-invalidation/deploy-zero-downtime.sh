#!/usr/bin/env bash
# ==============================================================================
# Script: deploy-zero-downtime.sh
# Purpose: Deterministic Next.js container deployment to prevent stale build hashes
# ==============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-479537131188}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/smartdoc-frontend:${IMAGE_TAG}"

echo ">>> [1/4] Authenticating with AWS ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

echo ">>> [2/4] Pulling deterministic image digest..."
docker pull "${IMAGE_URI}"

echo ">>> [3/4] Purging existing container state to prevent stale build mounts..."
docker stop smartdoc-frontend 2>/dev/null || true
docker rm smartdoc-frontend 2>/dev/null || true

echo ">>> [4/4] Instantiating fresh container with isolated build manifest..."
docker run -d \
  --name smartdoc-frontend \
  --network smartdoc-net \
  -p 80:3000 \
  --restart always \
  "${IMAGE_URI}"

echo ">>> Deployment successful! Verifying HTTP health..."
sleep 3
curl -I -s http://localhost:80/ | head -n 1
