#!/bin/bash
set -euo pipefail

# Compare results across all 3 clusters
# Usage: ./4-compare-results.sh <baseline-cluster> <perfarray-cluster> <ringbuf-cluster>

BASELINE="${1:?Usage: $0 <baseline-cluster> <perfarray-cluster> <ringbuf-cluster>}"
PERFARRAY="${2:?}"
RINGBUF="${3:?}"

echo "============================================"
echo "  RING BUFFER vs PERF ARRAY COMPARISON"
echo "============================================"
echo ""

for CLUSTER in "$BASELINE" "$PERFARRAY" "$RINGBUF"; do
    FILE="/tmp/${CLUSTER}_results.txt"
    if [[ ! -f "$FILE" ]]; then
        echo "ERROR: Results file not found: $FILE"
        echo "       Run ./3-run-test.sh $CLUSTER <rg> first"
        exit 1
    fi
done

printf "%-20s %-15s %-15s %-15s\n" "Metric" "No Retina" "Perf Array" "Ring Buffer"
printf "%-20s %-15s %-15s %-15s\n" "------" "---------" "----------" "-----------"

# Extract peak throughput from each
for CLUSTER in "$BASELINE" "$PERFARRAY" "$RINGBUF"; do
    FILE="/tmp/${CLUSTER}_results.txt"
    # Get the highest Gb/s value from throughput lines
    PEAK=$(grep -oP '[\d.]+\s+Gb/s' "$FILE" 2>/dev/null | sort -rn | head -1 || echo "N/A")
    DROPS=$(grep "drops" "$FILE" 2>/dev/null | awk '{sum += $2} END {printf "%d", sum}' || echo "0")

    if [[ "$CLUSTER" == "$BASELINE" ]]; then
        BASELINE_PEAK="$PEAK"
        BASELINE_DROPS="$DROPS"
    elif [[ "$CLUSTER" == "$PERFARRAY" ]]; then
        PERFARRAY_PEAK="$PEAK"
        PERFARRAY_DROPS="$DROPS"
    else
        RINGBUF_PEAK="$PEAK"
        RINGBUF_DROPS="$DROPS"
    fi
done

printf "%-20s %-15s %-15s %-15s\n" "Peak throughput" "${BASELINE_PEAK:-N/A}" "${PERFARRAY_PEAK:-N/A}" "${RINGBUF_PEAK:-N/A}"
printf "%-20s %-15s %-15s %-15s\n" "Total drops" "${BASELINE_DROPS:-0}" "${PERFARRAY_DROPS:-0}" "${RINGBUF_DROPS:-0}"

echo ""
echo "Individual result files:"
echo "  /tmp/${BASELINE}_results.txt"
echo "  /tmp/${PERFARRAY}_results.txt"
echo "  /tmp/${RINGBUF}_results.txt"
