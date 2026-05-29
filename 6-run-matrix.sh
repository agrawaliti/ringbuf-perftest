#!/bin/bash
set -euo pipefail

# Run a parameter sweep for load, packet size, and qps against one cluster.
# Usage: ./6-run-matrix.sh <cluster-name> <resource-group> [duration_secs] [results_dir]
# Optional env overrides:
#   MATRIX_REPLICAS="10 20"
#   MATRIX_CONNS="8 16 32"
#   MATRIX_PAYLOADS="512 1024 4096"
#   MATRIX_QPS="0 5000"

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <resource-group> [duration_secs] [results_dir]}"
RG="${2:?Usage: $0 <cluster-name> <resource-group> [duration_secs] [results_dir]}"
DURATION="${3:-120}"
RESULTS_BASE="${4:-/tmp/ringbuf-matrix-results}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date +%m%d%H%M)"
MATRIX_ROOT="${RESULTS_BASE}/${CLUSTER_NAME}/matrix-${TIMESTAMP}"
mkdir -p "$MATRIX_ROOT"

MATRIX_REPLICAS="${MATRIX_REPLICAS:-20}"
MATRIX_CONNS="${MATRIX_CONNS:-8 16 32}"
MATRIX_PAYLOADS="${MATRIX_PAYLOADS:-512 4096 16384}"
MATRIX_QPS="${MATRIX_QPS:-0 5000}"

echo "============================================"
echo "Running matrix test on: $CLUSTER_NAME"
echo "Duration: ${DURATION}s"
echo "Results root: $MATRIX_ROOT"
echo "Replicas: $MATRIX_REPLICAS"
echo "Conns/pod: $MATRIX_CONNS"
echo "Payloads: $MATRIX_PAYLOADS"
echo "QPS/conn: $MATRIX_QPS"
echo "============================================"

i=0
for replicas in $MATRIX_REPLICAS; do
  for conns in $MATRIX_CONNS; do
    for payload in $MATRIX_PAYLOADS; do
      for qps in $MATRIX_QPS; do
        i=$((i + 1))
        run_id="r${replicas}-c${conns}-p${payload}-q${qps}"
        run_dir="${MATRIX_ROOT}/${run_id}"

        echo ""
        echo "[$i] Matrix run: $run_id"
        echo "  replicas=$replicas conns=$conns payload=$payload qps=$qps"

        "$SCRIPT_DIR/3-run-test.sh" \
          "$CLUSTER_NAME" \
          "$RG" \
          "$DURATION" \
          "$run_dir" \
          "$replicas" \
          "$conns" \
          "$payload" \
          "$qps"
      done
    done
  done
done

echo ""
echo "All matrix runs complete."
echo "Root: $MATRIX_ROOT"

echo ""
echo "Quick summary:"
printf "%-24s %-12s %-12s\n" "Run" "Peak Gb/s" "Drops"
printf "%-24s %-12s %-12s\n" "---" "---" "---"

find "$MATRIX_ROOT" -name summary.txt | sort | while read -r summary; do
  run_name="$(basename "$(dirname "$summary")")"
  recv_log="$(dirname "$summary")/receiver-full.log"
  peak="$(grep -oP '[0-9]+(\.[0-9]+)?\s*Gb/s' "$recv_log" 2>/dev/null | awk '{print $1}' | sort -rn | head -1 || true)"
  drops="$(grep 'TOTAL softirq drops' "$summary" 2>/dev/null | grep -oP '[0-9]+' | tail -1 || true)"
  printf "%-24s %-12s %-12s\n" "$run_name" "${peak:-N/A}" "${drops:-N/A}"
done
