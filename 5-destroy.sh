#!/bin/bash
set -euo pipefail

# Destroy all test clusters
# Usage: ./5-destroy.sh <timestamp>
# Example: ./5-destroy.sh 05211430

TIMESTAMP="${1:?Usage: $0 <timestamp> (from cluster creation)}"
PREFIX="ringbuf-test"

for VARIANT in baseline perfarray ringbuf; do
    RG="${PREFIX}-${VARIANT}-${TIMESTAMP}-rg"
    echo "Deleting resource group: $RG"
    az group delete --name "$RG" --yes --no-wait || true
done

echo "All resource groups queued for deletion."
