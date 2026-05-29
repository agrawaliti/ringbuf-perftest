#!/bin/bash
# Falcon NUMA reproduction test.
#
# Runs the microservice-fanout scenario (the scenario where PA struggled most
# in our D32s_v3 tests) on 96-vCPU 4-NUMA Standard_D96as_v5 nodes to
# reproduce the cross-NUMA buffer polling collapse documented by the Falcon team.
#
# What we expect to see (vs D32s_v3 results):
#   - PA throughput cap much lower than RB (Falcon saw 2.2x single-flow penalty)
#   - PA Retina CPU much higher (more buffers × more NUMA nodes to drain)
#   - RB still reaches NIC ceiling with low Retina CPU
#
# Usage:
#   ./9-falcon-numa-test.sh [duration_secs] [results_root]
#
# Defaults:
#   duration   = 300s
#   results    = results/falcon-numa-<timestamp>/

set -euo pipefail

DURATION="${1:-300}"
TIMESTAMP=$(date +%m%d%H%M)
RESULTS_ROOT="${2:-$(pwd)/results/falcon-numa-${TIMESTAMP}}"

export VM_SIZE_SYSTEM="Standard_D4s_v3"
export VM_SIZE_32CORE="Standard_D96as_v5"   # 96 vCPU, 4 NUMA nodes — Falcon-class
export LOCATION="${LOCATION:-canadacentral}"
export PREFIX="fn"

mkdir -p "${RESULTS_ROOT}/logs"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Falcon NUMA Reproduction — microservice-fanout             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Node SKU   : $VM_SIZE_32CORE  (96 vCPU, 4 NUMA nodes)"
echo "Scenario   : microservice-fanout  (40p × 4c × 256B × ∞ QPS)"
echo "Duration   : ${DURATION}s"
echo "Results    : $RESULTS_ROOT"
echo ""
echo "Expected findings on 4-NUMA vs single-NUMA (D32s_v3):"
echo "  PA: cross-NUMA buffer polling → CPU saturation → lower throughput"
echo "  RB: single shared buffer, NUMA-agnostic → flat CPU, NIC-saturated"
echo ""

exec ./8-cross-variant-scenarios.sh "$DURATION" microservice-fanout "$RESULTS_ROOT"
