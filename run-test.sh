#!/bin/bash
set -euo pipefail

# Ring Buffer vs Perf Array Performance Test
# Replicates the traffic pattern from:
# https://blog.zmalik.dev/p/who-will-observe-the-observability
#
# Traffic: Multiple client pods (unique IPs) → SO_REUSEPORT receiver
# Key: Kernel distributes SYNs across cores via flow hash on source IPs
# This creates genuine multi-core packet processing load

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="perf-test"
REGISTRY="${REGISTRY:-}"  # Set to your ACR, e.g. myacr.azurecr.io
DURATION="${DURATION:-120}"
CLIENT_REPLICAS="${CLIENT_REPLICAS:-20}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  build       Build and push container images
  deploy      Deploy receiver + monitor (no clients yet)
  baseline    Run throughput test WITHOUT retina (or with retina disabled)
  test        Run throughput test (clients flood for DURATION seconds)
  results     Show receiver throughput from logs
  softirq     Show softirq stats from monitor pod
  cleanup     Delete test workloads

Environment:
  REGISTRY          Container registry (required for build/deploy)
  DURATION          Test duration in seconds (default: 120)
  CLIENT_REPLICAS   Number of client pods (default: 20)

Example workflow:
  export REGISTRY=myacr.azurecr.io
  $0 build
  $0 deploy
  $0 baseline      # measure without retina
  # ... enable retina with perf array ...
  $0 test          # measure with perf array
  $0 results
  $0 softirq
  # ... switch retina to ring buffer ...
  $0 test          # measure with ring buffer
  $0 results
  $0 softirq
  $0 cleanup
EOF
}

cmd_build() {
    if [[ -z "$REGISTRY" ]]; then
        err "REGISTRY not set. Export REGISTRY=<your-acr>.azurecr.io"
        exit 1
    fi

    log "Building receiver image..."
    docker build -t "$REGISTRY/ringbuf-receiver:latest" -f "$SCRIPT_DIR/Dockerfile.receiver" "$SCRIPT_DIR"

    log "Building client image..."
    docker build -t "$REGISTRY/ringbuf-client:latest" -f "$SCRIPT_DIR/Dockerfile.client" "$SCRIPT_DIR"

    log "Pushing images..."
    docker push "$REGISTRY/ringbuf-receiver:latest"
    docker push "$REGISTRY/ringbuf-client:latest"

    log "Images pushed to $REGISTRY"
}

cmd_deploy() {
    if [[ -z "$REGISTRY" ]]; then
        err "REGISTRY not set. Export REGISTRY=<your-acr>.azurecr.io"
        exit 1
    fi

    log "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    log "Deploying receiver..."
    sed "s|REGISTRY|$REGISTRY|g" "$SCRIPT_DIR/deploy/receiver.yaml" | kubectl apply -f -

    log "Deploying monitor pod..."
    kubectl apply -f "$SCRIPT_DIR/deploy/monitor.yaml"

    log "Waiting for receiver to be ready..."
    kubectl rollout status deployment/tcp-receiver -n "$NAMESPACE" --timeout=120s

    log "Waiting for monitor pod..."
    kubectl wait --for=condition=Ready pod/softirq-monitor -n "$NAMESPACE" --timeout=60s

    RECV_POD=$(kubectl get pods -n "$NAMESPACE" -l app=tcp-receiver -o jsonpath='{.items[0].metadata.name}')
    RECV_NODE=$(kubectl get pod "$RECV_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
    log "Receiver running on node: $RECV_NODE"
    log "Deploy complete. Run '$0 test' to start client flood."
}

cmd_test() {
    if [[ -z "$REGISTRY" ]]; then
        err "REGISTRY not set. Export REGISTRY=<your-acr>.azurecr.io"
        exit 1
    fi

    log "Taking softirq baseline..."
    kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/softnet_stat > /tmp/softirq_before.txt

    log "Deploying $CLIENT_REPLICAS client pods (duration=${DURATION}s)..."
    sed "s|REGISTRY|$REGISTRY|g; s|replicas: 20|replicas: $CLIENT_REPLICAS|g; s|duration=120s|duration=${DURATION}s|g" \
        "$SCRIPT_DIR/deploy/client.yaml" | kubectl apply -f -

    log "Waiting for clients to start..."
    kubectl rollout status deployment/tcp-client -n "$NAMESPACE" --timeout=120s

    log "Test running for ${DURATION}s... monitoring throughput:"
    echo ""

    # Poll receiver logs for throughput reports
    RECV_POD=$(kubectl get pods -n "$NAMESPACE" -l app=tcp-receiver -o jsonpath='{.items[0].metadata.name}')
    END_TIME=$(($(date +%s) + DURATION + 10))

    while [[ $(date +%s) -lt $END_TIME ]]; do
        kubectl logs "$RECV_POD" -n "$NAMESPACE" --tail=1 2>/dev/null || true
        sleep 5
    done

    echo ""
    log "Test complete. Capturing final softirq..."
    kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/softnet_stat > /tmp/softirq_after.txt

    log "Cleaning up clients..."
    kubectl delete deployment tcp-client -n "$NAMESPACE" --ignore-not-found

    cmd_results
    echo ""
    cmd_softirq
}

cmd_results() {
    RECV_POD=$(kubectl get pods -n "$NAMESPACE" -l app=tcp-receiver -o jsonpath='{.items[0].metadata.name}')
    log "Receiver throughput (last 20 reports):"
    echo ""
    kubectl logs "$RECV_POD" -n "$NAMESPACE" --tail=20
}

cmd_softirq() {
    if [[ -f /tmp/softirq_before.txt && -f /tmp/softirq_after.txt ]]; then
        log "Softirq delta (drops column):"
        echo ""
        paste /tmp/softirq_before.txt /tmp/softirq_after.txt | awk '{
            before_drops = strtonum("0x"$2)
            after_drops  = strtonum("0x"$(NF/2+2))
            delta = after_drops - before_drops
            if (delta > 0) printf "CPU %d: +%d drops\n", NR-1, delta
        }'
    else
        log "Live softirq stats (CPUs with drops):"
        kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/softnet_stat | \
            awk '{d=strtonum("0x"$2); if(d>0) printf "CPU %d: drops=%d squeeze=%d\n", NR-1, d, strtonum("0x"$3)}'
    fi
}

cmd_cleanup() {
    log "Deleting test workloads..."
    kubectl delete deployment tcp-client -n "$NAMESPACE" --ignore-not-found
    kubectl delete deployment tcp-receiver -n "$NAMESPACE" --ignore-not-found
    kubectl delete service tcp-receiver -n "$NAMESPACE" --ignore-not-found
    kubectl delete pod softirq-monitor -n "$NAMESPACE" --ignore-not-found
    log "Cleanup done. Namespace $NAMESPACE preserved."
}

# Main
case "${1:-}" in
    build)   cmd_build ;;
    deploy)  cmd_deploy ;;
    test)    cmd_test ;;
    baseline) cmd_test ;;
    results) cmd_results ;;
    softirq) cmd_softirq ;;
    cleanup) cmd_cleanup ;;
    *)       usage ;;
esac
