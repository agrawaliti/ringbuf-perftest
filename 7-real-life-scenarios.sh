#!/bin/bash
set -euo pipefail

# Run realistic traffic profiles on one cluster.
# Usage: ./7-real-life-scenarios.sh <cluster-name> <resource-group> <scenario|all> [duration_secs] [results_dir]
#
# QPS values accept plain or suffix form (e.g., 5000, 5k, 2m).

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <resource-group> <scenario|all> [duration_secs] [results_dir]}"
RG="${2:?Usage: $0 <cluster-name> <resource-group> <scenario|all> [duration_secs] [results_dir]}"
SCENARIO="${3:?Usage: $0 <cluster-name> <resource-group> <scenario|all> [duration_secs] [results_dir]}"
DURATION="${4:-900}"
RESULTS_BASE="${5:-/tmp/ringbuf-real-scenarios}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date +%m%d%H%M)"
ROOT="${RESULTS_BASE}/${CLUSTER_NAME}/real-${TIMESTAMP}"
mkdir -p "$ROOT"

run_one() {
  local name="$1"
  local replicas="$2"
  local conns="$3"
  local payload="$4"
  local qps="$5"

  local out_dir="${ROOT}/${name}"
  echo ""
  echo "=== Scenario: ${name} ==="
  echo "replicas=${replicas} conns/pod=${conns} payload=${payload}B qps/conn=${qps} duration=${DURATION}s"

  "$SCRIPT_DIR/3-run-test.sh" \
    "$CLUSTER_NAME" \
    "$RG" \
    "$DURATION" \
    "$out_dir" \
    "$replicas" \
    "$conns" \
    "$payload" \
    "$qps"
}

show_catalog() {
  cat <<'EOF'
Available scenarios:
  api-read-heavy      Many small request/response calls (576 streams, 512B, 8k QPS)
  grpc-streaming      Medium payload steady streams (320 streams, 2KB, 2k QPS)
  iot-telemetry       High-QPS tiny payload ingestion (360 streams, 128B, 20k QPS)
  log-shipper         Large payload, lower QPS sustained writes (120 streams, 16KB, 400 QPS)
  mixed-web-spiky     Mixed workload with burst-friendly QPS (400 streams, 1KB, 5k QPS)
  low-load            Light production traffic ~64MB/s (16 streams, 1KB, 1k QPS)
  microservice-fanout Many connections, small msgs, unlimited QPS (160 streams, 256B)
  bulk-ingest         Large payload max bandwidth (64 streams, 64KB, unlimited)
  all                 Run all 8 scenarios sequentially
EOF
}

case "$SCENARIO" in
  api-read-heavy)
    run_one "api-read-heavy" 24 24 512 8k
    ;;
  grpc-streaming)
    run_one "grpc-streaming" 20 16 2048 2k
    ;;
  iot-telemetry)
    run_one "iot-telemetry" 30 12 128 20k
    ;;
  log-shipper)
    run_one "log-shipper" 12 10 16384 400
    ;;
  mixed-web-spiky)
    run_one "mixed-web-spiky" 20 20 1024 5k
    ;;
  low-load)
    # Light production traffic: ~64 MB/s total — measures Retina overhead at rest
    run_one "low-load" 4 4 1024 1k
    ;;
  microservice-fanout)
    # Many small connections, small msgs — stresses per-packet eBPF cost
    run_one "microservice-fanout" 40 4 256 0
    ;;
  bulk-ingest)
    # Large payload, max bandwidth — analytics/ML ingest pattern
    run_one "bulk-ingest" 8 8 65536 0
    ;;
  all)
    run_one "api-read-heavy" 24 24 512 8k
    run_one "grpc-streaming" 20 16 2048 2k
    run_one "iot-telemetry" 30 12 128 20k
    run_one "log-shipper" 12 10 16384 400
    run_one "mixed-web-spiky" 20 20 1024 5k
    run_one "low-load" 4 4 1024 1k
    run_one "microservice-fanout" 40 4 256 0
    run_one "bulk-ingest" 8 8 65536 0
    ;;
  *)
    echo "Unknown scenario: $SCENARIO"
    show_catalog
    exit 1
    ;;
esac

echo ""
echo "Completed scenario run(s). Results root: $ROOT"
