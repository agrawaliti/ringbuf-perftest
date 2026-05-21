#!/bin/bash
set -euo pipefail

# Sequential test runner: creates one cluster at a time, tests, saves results, destroys.
# Fits within 84 available DSv3 vCPUs (needs ~76 per cluster).
#
# Usage: ./run-sequential.sh [duration_secs]

DURATION="${1:-120}"
LOCATION="canadacentral"
VM_SIZE_SYSTEM="Standard_D4s_v3"
VM_SIZE_32CORE="Standard_D32s_v3"
K8S_VERSION="1.34"
PREFIX="rbt"
TIMESTAMP=$(date +%m%d%H%M)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="/tmp/ringbuf-results-${TIMESTAMP}"

mkdir -p "$RESULTS_DIR"

# Test configurations: name | retina_mode
# retina_mode: "none" = no retina, "disabled" = perf array, "enabled" = ring buffer
declare -A CONFIGS
CONFIGS=(
    [base]="none"
    [pa]="disabled"
    [rb]="enabled"
)

# Order matters - run baseline first
ORDER=(base pa rb)

echo "============================================"
echo "Sequential Ring Buffer Perf Test"
echo "Timestamp: $TIMESTAMP"
echo "Duration: ${DURATION}s per test"
echo "Results: $RESULTS_DIR"
echo "============================================"
echo ""

for VARIANT in "${ORDER[@]}"; do
    RETINA_MODE="${CONFIGS[$VARIANT]}"
    CLUSTER_NAME="${PREFIX}-${VARIANT}-${TIMESTAMP}"
    RG_NAME="${CLUSTER_NAME}-rg"

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║ Phase: $VARIANT (retina: $RETINA_MODE)"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    # --- CREATE CLUSTER ---
    echo "[INFRA] Creating resource group: $RG_NAME"
    az group create --name "$RG_NAME" --location "$LOCATION" -o none

    echo "[INFRA] Creating AKS cluster: $CLUSTER_NAME"
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

    echo "[INFRA] Adding 32-core nodepool (2 nodes)..."
    az aks nodepool add \
        --resource-group "$RG_NAME" \
        --cluster-name "$CLUSTER_NAME" \
        --name np32core \
        --node-count 2 \
        --node-vm-size "$VM_SIZE_32CORE" \
        --mode User \
        -o none

    echo "[INFRA] Attaching ACR..."
    az aks update \
        --resource-group "$RG_NAME" \
        --name "$CLUSTER_NAME" \
        --attach-acr acndev \
        -o none 2>/dev/null || echo "  (ACR attach skipped)"

    # --- INSTALL RETINA (if needed) ---
    if [[ "$RETINA_MODE" != "none" ]]; then
        echo "[RETINA] Installing with packetParserRingBuffer=$RETINA_MODE"
        "$SCRIPT_DIR/2-setup-retina.sh" "$CLUSTER_NAME" "$RG_NAME" "$RETINA_MODE"
    else
        echo "[RETINA] Skipping (baseline)"
        az aks get-credentials --resource-group "$RG_NAME" --name "$CLUSTER_NAME" --overwrite-existing
    fi

    # --- RUN TEST ---
    echo "[TEST] Running throughput test (${DURATION}s)..."
    "$SCRIPT_DIR/3-run-test.sh" "$CLUSTER_NAME" "$RG_NAME" "$DURATION" "$RESULTS_DIR"

    # --- DESTROY CLUSTER ---
    echo "[CLEANUP] Destroying $RG_NAME..."
    az group delete --name "$RG_NAME" --yes --no-wait
    echo "[CLEANUP] Deletion queued (async)"
    echo ""
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║ ALL TESTS COMPLETE                          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Results in: $RESULTS_DIR"
echo ""

# --- COMPARE RESULTS ---
echo "========== COMPARISON =========="
echo ""
printf "%-12s  %-12s  %-15s  %-20s\n" "Variant" "Peak Gb/s" "Softirq Drops" "Map Type"
printf "%-12s  %-12s  %-15s  %-20s\n" "--------" "---------" "-------------" "--------"

for VARIANT in "${ORDER[@]}"; do
    CLUSTER="${PREFIX}-${VARIANT}-${TIMESTAMP}"
    SUMMARY_FILE="$RESULTS_DIR/${CLUSTER}/summary.txt"
    RECV_LOG="$RESULTS_DIR/${CLUSTER}/receiver-full.log"
    EBPF_FILE="$RESULTS_DIR/${CLUSTER}/ebpf-maps-posttest.txt"

    if [[ -f "$SUMMARY_FILE" ]]; then
        PEAK=$(grep -oP '[\d.]+\s*Gb/s' "$RECV_LOG" 2>/dev/null | awk '{print $1}' | sort -rn | head -1 || echo "N/A")
        DROPS=$(grep "TOTAL softirq drops" "$SUMMARY_FILE" | grep -oP '\d+' || echo "0")
        MAP_TYPE=$(grep -oP 'ringbuf|perf_event_array' "$EBPF_FILE" 2>/dev/null | head -1 || echo "none")
        printf "%-12s  %-12s  %-15s  %-20s\n" "$VARIANT" "${PEAK:-N/A}" "${DROPS:-0}" "${MAP_TYPE:-none}"
    else
        printf "%-12s  %-12s  %-15s  %-20s\n" "$VARIANT" "MISSING" "MISSING" "MISSING"
    fi
done

echo ""
echo "Full results tree:"
find "$RESULTS_DIR" -type f | sort
echo ""
echo "Done. Timestamp: $TIMESTAMP"
