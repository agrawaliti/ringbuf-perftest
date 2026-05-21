#!/bin/bash
set -e

REGISTRY="acndev.azurecr.io"
ACR_IP=$(dig +short "$REGISTRY" | tail -1)
RESOLVE="--resolve ${REGISTRY}:443:${ACR_IP}"

echo "Registry: $REGISTRY (IP: $ACR_IP)"

# Get tokens
AAD_TOKEN=$(az account get-access-token --query accessToken -o tsv)
ACR_REFRESH=$(curl -sS --connect-timeout 10 $RESOLVE \
  -X POST "https://${REGISTRY}/oauth2/exchange" \
  -d "grant_type=access_token&service=${REGISTRY}&access_token=$AAD_TOKEN" | jq -r .refresh_token)

push_image() {
  local OCI_DIR=$1
  local REPO=$2
  local TAG=$3

  echo "=== Pushing $REPO:$TAG ==="

  # Get scoped token for this repo
  local TOKEN=$(curl -sS --connect-timeout 10 $RESOLVE \
    -X POST "https://${REGISTRY}/oauth2/token" \
    -d "grant_type=refresh_token&service=${REGISTRY}&scope=repository:${REPO}:pull,push&refresh_token=$ACR_REFRESH" | jq -r .access_token)

  local AUTH="Authorization: Bearer $TOKEN"

  # Read manifest from index.json
  local MANIFEST_DIGEST=$(cat "$OCI_DIR/index.json" | jq -r '.manifests[0].digest')
  local MANIFEST_FILE="$OCI_DIR/blobs/${MANIFEST_DIGEST/://}"
  
  # Get config and layer digests from manifest
  local CONFIG_DIGEST=$(jq -r '.config.digest' "$MANIFEST_FILE")
  local CONFIG_SIZE=$(jq -r '.config.size' "$MANIFEST_FILE")
  
  # Push each layer
  for LAYER_DIGEST in $(jq -r '.layers[].digest' "$MANIFEST_FILE"); do
    local LAYER_FILE="$OCI_DIR/blobs/${LAYER_DIGEST/://}"
    local LAYER_SIZE=$(stat -c%s "$LAYER_FILE")
    
    # Check if blob exists
    local STATUS=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 $RESOLVE \
      -H "$AUTH" \
      "https://${REGISTRY}/v2/${REPO}/blobs/${LAYER_DIGEST}")
    
    if [ "$STATUS" = "200" ]; then
      echo "  Layer $LAYER_DIGEST already exists"
    else
      echo "  Uploading layer ($LAYER_SIZE bytes)..."
      # Start upload - Location is relative path
      local UPLOAD_PATH=$(curl -sS -D- --connect-timeout 10 $RESOLVE \
        -H "$AUTH" \
        -X POST "https://${REGISTRY}/v2/${REPO}/blobs/uploads/" | grep -i "^location:" | tr -d '\r' | awk '{print $2}')
      
      # Upload blob in single PUT (images are small)
      curl -sS --connect-timeout 30 $RESOLVE \
        -H "$AUTH" \
        -H "Content-Type: application/octet-stream" \
        -X PUT "https://${REGISTRY}${UPLOAD_PATH}&digest=${LAYER_DIGEST}" \
        --data-binary "@${LAYER_FILE}" -o /dev/null -w "  Layer upload HTTP %{http_code}\n"
    fi
  done

  # Push config blob
  local CONFIG_FILE="$OCI_DIR/blobs/${CONFIG_DIGEST/://}"
  local STATUS=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 $RESOLVE \
    -H "$AUTH" \
    "https://${REGISTRY}/v2/${REPO}/blobs/${CONFIG_DIGEST}")
  
  if [ "$STATUS" = "200" ]; then
    echo "  Config $CONFIG_DIGEST already exists"
  else
    echo "  Uploading config ($CONFIG_SIZE bytes)..."
    local UPLOAD_PATH=$(curl -sS -D- --connect-timeout 10 $RESOLVE \
      -H "$AUTH" \
      -X POST "https://${REGISTRY}/v2/${REPO}/blobs/uploads/" | grep -i "^location:" | tr -d '\r' | awk '{print $2}')
    
    curl -sS --connect-timeout 30 $RESOLVE \
      -H "$AUTH" \
      -H "Content-Type: application/octet-stream" \
      -X PUT "https://${REGISTRY}${UPLOAD_PATH}&digest=${CONFIG_DIGEST}" \
      --data-binary "@${CONFIG_FILE}" -o /dev/null -w "  Config upload HTTP %{http_code}\n"
  fi

  # Push manifest
  echo "  Uploading manifest..."
  curl -sS --connect-timeout 10 $RESOLVE \
    -H "$AUTH" \
    -H "Content-Type: application/vnd.oci.image.manifest.v1+json" \
    -X PUT "https://${REGISTRY}/v2/${REPO}/manifests/${TAG}" \
    --data-binary "@${MANIFEST_FILE}" -o /dev/null -w "  Manifest upload HTTP %{http_code}\n"

  echo "  Done: $REGISTRY/$REPO:$TAG"
}

push_image "/tmp/oci-receiver" "ringbuf-receiver" "latest"
push_image "/tmp/oci-client" "ringbuf-client" "latest"

echo ""
echo "Both images pushed to $REGISTRY"
