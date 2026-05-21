#!/bin/bash
set -euo pipefail

# Build and push test images to acndev ACR
# Usage: ./0-build-images.sh

REGISTRY="acndev.azurecr.io"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building and pushing images to $REGISTRY..."
echo ""

# Login to ACR
echo "[1/4] Logging into ACR..."
az acr login --name acndev

# Build receiver
echo "[2/4] Building receiver..."
docker build -t "$REGISTRY/ringbuf-receiver:latest" -f "$SCRIPT_DIR/Dockerfile.receiver" "$SCRIPT_DIR"

# Build client
echo "[3/4] Building client..."
docker build -t "$REGISTRY/ringbuf-client:latest" -f "$SCRIPT_DIR/Dockerfile.client" "$SCRIPT_DIR"

# Push
echo "[4/4] Pushing images..."
docker push "$REGISTRY/ringbuf-receiver:latest"
docker push "$REGISTRY/ringbuf-client:latest"

echo ""
echo "Done. Images available:"
echo "  $REGISTRY/ringbuf-receiver:latest"
echo "  $REGISTRY/ringbuf-client:latest"
