#!/bin/bash
set -euo pipefail

# Provision 3 identical AKS clusters for ring buffer perf comparison:
#   1. baseline    - No Retina
#   2. perf-array  - Retina with packetParserRingBuffer=disabled
#   3. ring-buffer - Retina with packetParserRingBuffer=enabled
#
# All clusters: Standard_D32s_v3, canadacentral, 2-node np32core pool + 3-node system pool

LOCATION="canadacentral"
VM_SIZE_SYSTEM="Standard_D4s_v3"
VM_SIZE_32CORE="Standard_D32s_v3"
K8S_VERSION="1.34"
PREFIX="ringbuf-test"
TIMESTAMP=$(date +%m%d%H%M)

CLUSTERS=("baseline" "perfarray" "ringbuf")

for VARIANT in "${CLUSTERS[@]}"; do
    CLUSTER_NAME="${PREFIX}-${VARIANT}-${TIMESTAMP}"
    RG_NAME="${CLUSTER_NAME}-rg"

    echo "============================================"
    echo "Creating cluster: $CLUSTER_NAME"
    echo "Resource group:   $RG_NAME"
    echo "============================================"

    # Create resource group
    az group create --name "$RG_NAME" --location "$LOCATION" -o none

    # Create cluster with system nodepool (3 nodes, small)
    az aks create \
        --resource-group "$RG_NAME" \
        --name "$CLUSTER_NAME" \
        --location "$LOCATION" \
        --kubernetes-version "$K8S_VERSION" \
        --node-count 3 \
        --node-vm-size "$VM_SIZE_SYSTEM" \
        --network-plugin azure \
        --network-plugin-mode overlay \
        --generate-ssh-keys \
        --tier standard \
        -o none

    # Add 32-core nodepool (2 nodes for client/server separation)
    az aks nodepool add \
        --resource-group "$RG_NAME" \
        --cluster-name "$CLUSTER_NAME" \
        --name np32core \
        --node-count 2 \
        --node-vm-size "$VM_SIZE_32CORE" \
        --mode User \
        -o none

    # Attach ACR
    az aks update \
        --resource-group "$RG_NAME" \
        --name "$CLUSTER_NAME" \
        --attach-acr acndev \
        -o none 2>/dev/null || echo "  (ACR attach skipped - may need manual pull secret)"

    echo "$CLUSTER_NAME READY"
    echo ""
done

echo "============================================"
echo "All 3 clusters created:"
for VARIANT in "${CLUSTERS[@]}"; do
    echo "  ${PREFIX}-${VARIANT}-${TIMESTAMP}"
done
echo ""
echo "Next steps:"
echo "  1. ./2-setup-retina.sh ${PREFIX}-perfarray-${TIMESTAMP}  ${PREFIX}-perfarray-${TIMESTAMP}-rg  disabled"
echo "  2. ./2-setup-retina.sh ${PREFIX}-ringbuf-${TIMESTAMP}    ${PREFIX}-ringbuf-${TIMESTAMP}-rg    enabled"
echo "  3. ./3-run-test.sh <cluster-name> <rg>"
echo "============================================"
