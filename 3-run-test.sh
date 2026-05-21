#!/bin/bash
set -euo pipefail

# Run the SO_REUSEPORT throughput test on a cluster with comprehensive logging.
# Captures: throughput, softirq, eBPF map sizes, retina logs, client logs.
# Usage: ./3-run-test.sh <cluster-name> <resource-group> [duration_secs] [results_dir]

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <resource-group> [duration_secs] [results_dir]}"
RG="${2:?Usage: $0 <cluster-name> <resource-group> [duration_secs] [results_dir]}"
DURATION="${3:-120}"
RESULTS_BASE="${4:-/tmp/ringbuf-results}"
NAMESPACE="perf-test"
REGISTRY="acndev.azurecr.io"
CLIENT_REPLICAS=20

# Create results directory
RESULTS_DIR="${RESULTS_BASE}/${CLUSTER_NAME}"
mkdir -p "$RESULTS_DIR"

echo "============================================"
echo "Running test on: $CLUSTER_NAME"
echo "Duration: ${DURATION}s | Clients: $CLIENT_REPLICAS pods"
echo "Results: $RESULTS_DIR"
echo "============================================"

# Get credentials
az aks get-credentials --resource-group "$RG" --name "$CLUSTER_NAME" --overwrite-existing

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- DEPLOY RECEIVER ---
echo "[1/8] Deploying receiver..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sed "s|REGISTRY|$REGISTRY|g" "$SCRIPT_DIR/deploy/receiver.yaml" | kubectl apply -f -
kubectl rollout status deployment/tcp-receiver -n "$NAMESPACE" --timeout=120s

RECV_POD=$(kubectl get pods -n "$NAMESPACE" -l app=tcp-receiver -o jsonpath='{.items[0].metadata.name}')
RECV_NODE=$(kubectl get pod "$RECV_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
echo "  Receiver on node: $RECV_NODE"

# --- DEPLOY MONITOR ---
echo "[2/8] Deploying monitor pod (bpftool + softirq)..."
kubectl apply -f "$SCRIPT_DIR/deploy/monitor.yaml"
kubectl wait --for=condition=Ready pod/softirq-monitor -n "$NAMESPACE" --timeout=180s
# Wait for bpftool installation
echo "  Waiting for bpftool to install (30s)..."
sleep 30

# --- SAVE CLUSTER & RETINA METADATA ---
echo "[3/8] Capturing cluster metadata..."
{
    echo "=== Cluster Info ==="
    echo "Cluster: $CLUSTER_NAME"
    echo "Resource Group: $RG"
    echo "Date: $(date -u)"
    echo "K8s version: $(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' || echo 'unknown')"
    echo ""
    echo "=== Nodes ==="
    kubectl get nodes -o wide
    echo ""
    echo "=== Node details (np32core) ==="
    kubectl get nodes -l agentpool=np32core -o json | jq '.items[] | {name: .metadata.name, cpu: .status.capacity.cpu, memory: .status.capacity.memory}'
    echo ""
    echo "=== Retina Pods ==="
    kubectl get pods -n kube-system -l k8s-app=retina -o wide 2>/dev/null || echo "No Retina installed"
    echo ""
    echo "=== Retina ConfigMap ==="
    kubectl get configmap retina-config -n kube-system -o yaml 2>/dev/null || echo "No retina-config"
} > "$RESULTS_DIR/cluster-info.txt" 2>&1

# --- CAPTURE RETINA LOGS (PRE-TEST) ---
echo "[4/8] Capturing Retina pre-test state..."
RETINA_POD=""
{
    RETINA_POD=$(kubectl get pods -n kube-system -l k8s-app=retina \
        --field-selector "spec.nodeName=$RECV_NODE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$RETINA_POD" ]]; then
        echo "=== Retina pod on receiver node: $RETINA_POD ==="
        echo ""
        echo "=== Retina logs (pre-test, last 100 lines) ==="
        kubectl logs "$RETINA_POD" -n kube-system --tail=100 2>/dev/null || true
    else
        echo "No Retina pod on receiver node (baseline test)"
    fi
} > "$RESULTS_DIR/retina-pretest.txt" 2>&1
echo "  Retina pod: ${RETINA_POD:-none}"

# --- CAPTURE eBPF MAP STATE (PRE-TEST) ---
echo "[5/8] Capturing eBPF map state (pre-test)..."
{
    echo "=== eBPF Maps (pre-test) ==="
    echo "Date: $(date -u)"
    echo ""

    # List all BPF maps (use nsenter to access host's bpftool)
    echo "--- All BPF maps ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show 2>&1 || \
    echo "bpftool not available"
    echo ""

    # Detailed retina/packet maps in JSON
    echo "--- Retina map details (JSON) ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show -j 2>/dev/null | \
        jq '[.[] | select(.name != null) | select(.name | test("retina|packet|event"; "i"))]' 2>/dev/null || echo "[]"
    echo ""

    # Ring buffer and perf event array maps specifically
    echo "--- Ring buffer & perf event array maps ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show -j 2>/dev/null | \
        jq '[.[] | select(.type == "ringbuf" or .type == "perf_event_array")]' 2>/dev/null || echo "[]"
    echo ""

    # All BPF programs
    echo "--- BPF programs ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool prog show 2>&1 | grep -B1 -A3 -i "retina\|packet\|kprobe\|tracepoint" || echo "No retina programs"
    echo ""

    # Memory info
    echo "--- BPF map memory summary ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show -j 2>/dev/null | \
        jq -r '.[] | "\(.id)\t\(.name // "unnamed")\t\(.type)\tmax_entries=\(.max_entries)\tbytes_memlock=\(.bytes_memlock // 0)"' 2>/dev/null || true
} > "$RESULTS_DIR/ebpf-maps-pretest.txt" 2>&1
echo "  eBPF maps captured ($(grep -c "^[0-9]" "$RESULTS_DIR/ebpf-maps-pretest.txt" 2>/dev/null || echo 0) entries)"

# --- CAPTURE SOFTIRQ BASELINE ---
echo "[6/8] Capturing softirq baseline..."
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/softnet_stat > "$RESULTS_DIR/softirq-before.txt"
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/softirqs > "$RESULTS_DIR/proc-softirqs-before.txt" 2>/dev/null || true
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/interrupts > "$RESULTS_DIR/proc-interrupts-before.txt" 2>/dev/null || true

# --- DEPLOY CLIENTS AND RUN TEST ---
echo "[7/8] Deploying $CLIENT_REPLICAS client pods (duration=${DURATION}s)..."
sed "s|REGISTRY|$REGISTRY|g; s|replicas: 20|replicas: $CLIENT_REPLICAS|; s|duration=120s|duration=${DURATION}s|" \
    "$SCRIPT_DIR/deploy/client.yaml" | kubectl apply -f -
kubectl rollout status deployment/tcp-client -n "$NAMESPACE" --timeout=180s

# Monitor throughput during test, sampling every 15s
echo ""
echo "  Test running... sampling throughput every 15s:"
THROUGHPUT_LOG="$RESULTS_DIR/throughput-live.txt"
> "$THROUGHPUT_LOG"

POLL_END=$(($(date +%s) + DURATION + 10))
while [[ $(date +%s) -lt $POLL_END ]]; do
    LINE=$(kubectl logs "$RECV_POD" -n "$NAMESPACE" --tail=1 2>/dev/null || echo "N/A")
    TS=$(date -u +"%H:%M:%S")
    echo "  [$TS] $LINE"
    echo "[$TS] $LINE" >> "$THROUGHPUT_LOG"
    sleep 15
done

# --- COLLECT ALL POST-TEST RESULTS ---
echo ""
echo "[8/8] Collecting final results..."

# Softirq after
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/softnet_stat > "$RESULTS_DIR/softirq-after.txt"
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/softirqs > "$RESULTS_DIR/proc-softirqs-after.txt" 2>/dev/null || true

# eBPF maps post-test
{
    echo "=== eBPF Maps (post-test) ==="
    echo "Date: $(date -u)"
    echo ""
    echo "--- All BPF maps ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show 2>&1 || echo "bpftool not available"
    echo ""
    echo "--- Retina map details (JSON) ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show -j 2>/dev/null | \
        jq '[.[] | select(.name != null) | select(.name | test("retina|packet|event"; "i"))]' 2>/dev/null || echo "[]"
    echo ""
    echo "--- Ring buffer & perf event array maps ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show -j 2>/dev/null | \
        jq '[.[] | select(.type == "ringbuf" or .type == "perf_event_array")]' 2>/dev/null || echo "[]"
    echo ""
    echo "--- BPF map memory summary ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- bpftool map show -j 2>/dev/null | \
        jq -r '.[] | "\(.id)\t\(.name // "unnamed")\t\(.type)\tmax_entries=\(.max_entries)\tbytes_memlock=\(.bytes_memlock // 0)"' 2>/dev/null || true
} > "$RESULTS_DIR/ebpf-maps-posttest.txt" 2>&1

# perf_event wakeup stats (key metric from the blog)
{
    echo "=== perf_event wakeups (from /proc/softirqs NET_RX delta) ==="
    echo ""
    if [[ -f "$RESULTS_DIR/proc-softirqs-before.txt" && -f "$RESULTS_DIR/proc-softirqs-after.txt" ]]; then
        echo "--- NET_RX before ---"
        grep "NET_RX" "$RESULTS_DIR/proc-softirqs-before.txt" || echo "N/A"
        echo ""
        echo "--- NET_RX after ---"
        grep "NET_RX" "$RESULTS_DIR/proc-softirqs-after.txt" || echo "N/A"
    fi
} > "$RESULTS_DIR/net-rx-delta.txt" 2>&1

# Receiver full logs
echo "  Saving receiver logs..."
kubectl logs "$RECV_POD" -n "$NAMESPACE" > "$RESULTS_DIR/receiver-full.log" 2>&1

# Client logs (all pods, last 10 lines each)
echo "  Saving client logs..."
{
    for POD in $(kubectl get pods -n "$NAMESPACE" -l app=tcp-client -o jsonpath='{.items[*].metadata.name}'); do
        echo "=== $POD ==="
        kubectl logs "$POD" -n "$NAMESPACE" --tail=10 2>/dev/null || echo "  (no logs)"
        echo ""
    done
} > "$RESULTS_DIR/client-all.log" 2>&1

# Retina logs post-test (full)
if [[ -n "$RETINA_POD" ]]; then
    echo "  Saving Retina logs..."
    kubectl logs "$RETINA_POD" -n kube-system > "$RESULTS_DIR/retina-posttest.log" 2>&1
fi

# --- COMPUTE SUMMARY ---
echo "  Computing summary..."
{
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║ TEST SUMMARY: $CLUSTER_NAME"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Cluster: $CLUSTER_NAME"
    echo "Date: $(date -u)"
    echo "Duration: ${DURATION}s"
    echo "Client replicas: $CLIENT_REPLICAS (each 16 conns = $((CLIENT_REPLICAS * 16)) total TCP streams)"
    echo "Receiver node: $RECV_NODE"
    echo ""
    echo "=== THROUGHPUT (last 10 reports from receiver) ==="
    kubectl logs "$RECV_POD" -n "$NAMESPACE" --tail=10 2>/dev/null || echo "N/A"
    echo ""
    echo "=== PEAK THROUGHPUT ==="
    PEAK=$(grep -oP '[\d.]+\s*Gb/s' "$RESULTS_DIR/receiver-full.log" 2>/dev/null | awk '{print $1}' | sort -rn | head -1 || echo "N/A")
    echo "  Peak: ${PEAK} Gb/s"
    echo ""
    echo "=== SOFTIRQ DROPS ==="
    paste "$RESULTS_DIR/softirq-before.txt" "$RESULTS_DIR/softirq-after.txt" | awk '{
        before_drops = strtonum("0x"$2)
        after_drops  = strtonum("0x"$(NF/2+2))
        delta = after_drops - before_drops
        total += delta
        if (delta > 0) printf "  CPU %02d: +%d drops\n", NR-1, delta
    } END { printf "\n  TOTAL softirq drops: %d\n", total }'
    echo ""
    echo "=== eBPF MAP SIZES ==="
    grep -E "ringbuf|perf_event|retina|packet" "$RESULTS_DIR/ebpf-maps-posttest.txt" 2>/dev/null | head -15 || echo "  No relevant maps"
    echo ""
    echo "=== RETINA CONFIG ==="
    kubectl get configmap retina-config -n kube-system -o jsonpath='{.data}' 2>/dev/null | \
        jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || echo "  No Retina (baseline)"
} > "$RESULTS_DIR/summary.txt" 2>&1

# Print summary to stdout
echo ""
cat "$RESULTS_DIR/summary.txt"

# --- CLEANUP ---
echo ""
echo "Cleaning up test pods..."
kubectl delete deployment tcp-client -n "$NAMESPACE" --ignore-not-found
kubectl delete deployment tcp-receiver -n "$NAMESPACE" --ignore-not-found
kubectl delete service tcp-receiver -n "$NAMESPACE" --ignore-not-found
kubectl delete pod softirq-monitor -n "$NAMESPACE" --ignore-not-found

echo ""
echo "═══════════════════════════════════════"
echo "Results saved to: $RESULTS_DIR/"
echo "═══════════════════════════════════════"
ls "$RESULTS_DIR/"
echo ""
echo "Done: $CLUSTER_NAME"
