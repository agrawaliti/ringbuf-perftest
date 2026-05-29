#!/bin/bash
set -euo pipefail

# Run the SO_REUSEPORT throughput test on a cluster with comprehensive logging.
# Captures: throughput, softirq, eBPF map sizes, retina logs, client logs.
# Usage: ./3-run-test.sh <cluster-name> <resource-group> [duration_secs] [results_dir] [client_replicas] [conns_per_pod] [payload_bytes] [qps_per_conn]

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <resource-group> [duration_secs] [results_dir]}"
RG="${2:?Usage: $0 <cluster-name> <resource-group> [duration_secs] [results_dir]}"
DURATION="${3:-120}"
RESULTS_BASE="${4:-/tmp/ringbuf-results}"
NAMESPACE="perf-test"
REGISTRY="acndev.azurecr.io"
CLIENT_REPLICAS="${5:-20}"
CONNS_PER_POD="${6:-16}"
PAYLOAD_BYTES="${7:-4096}"
QPS_PER_CONN="${8:-0}"

# Optional per-cluster kubeconfig for parallel runs (set by 8-cross-variant-scenarios.sh)
if [[ -n "${KUBECONFIG_FILE:-}" ]]; then
    export KUBECONFIG="$KUBECONFIG_FILE"
fi

# Verbose timestamped logger — all output also goes to RESULTS_DIR/run.log once set
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Create results directory
RESULTS_DIR="${RESULTS_BASE}/${CLUSTER_NAME}"
mkdir -p "$RESULTS_DIR"

log "============================================"
log "Running test on: $CLUSTER_NAME"
log "Duration: ${DURATION}s | Clients: $CLIENT_REPLICAS pods"
log "Load profile: conns/pod=${CONNS_PER_POD} payload=${PAYLOAD_BYTES}B qps/conn=${QPS_PER_CONN}"
log "Results: $RESULTS_DIR"
log "KUBECONFIG: ${KUBECONFIG:-default}"
log "============================================"

# Get credentials (into per-cluster kubeconfig if KUBECONFIG_FILE is set)
if [[ -n "${KUBECONFIG_FILE:-}" ]]; then
    az aks get-credentials --resource-group "$RG" --name "$CLUSTER_NAME" --file "$KUBECONFIG_FILE" --overwrite-existing
else
    az aks get-credentials --resource-group "$RG" --name "$CLUSTER_NAME" --overwrite-existing
fi

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- DEPLOY RECEIVER ---
log "[1/8] Deploying receiver..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sed "s|REGISTRY|$REGISTRY|g" "$SCRIPT_DIR/deploy/receiver.yaml" | kubectl apply -f -
kubectl rollout status deployment/tcp-receiver -n "$NAMESPACE" --timeout=120s

RECV_POD=$(kubectl get pods -n "$NAMESPACE" -l app=tcp-receiver -o jsonpath='{.items[0].metadata.name}')
RECV_NODE=$(kubectl get pod "$RECV_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
log "  Receiver pod: $RECV_POD  node: $RECV_NODE"

# --- DEPLOY MONITOR ---
log "[2/8] Deploying monitor pod (bpftool + softirq)..."
kubectl apply -f "$SCRIPT_DIR/deploy/monitor.yaml"
kubectl wait --for=condition=Ready pod/softirq-monitor -n "$NAMESPACE" --timeout=180s
# Wait for bpftool installation
log "  Waiting for bpftool to install (30s)..."
sleep 30
log "  Monitor pod ready"

# --- SAVE CLUSTER & RETINA METADATA ---
log "[3/8] Capturing cluster metadata..."
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
log "[4/8] Capturing Retina pre-test state..."
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
log "  Retina pod: ${RETINA_POD:-none}"

# --- CAPTURE KERNEL NETWORK TUNABLES ---
log "[4.5/8] Capturing kernel/sysctl network configuration..."
{
    echo "=== Kernel and Network Tunables ==="
    echo "Date: $(date -u)"
    echo "Node: $RECV_NODE"
    echo ""
    echo "--- Kernel release ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- uname -a 2>/dev/null || true
    echo ""
    echo "--- Key net.core/net.ipv4 sysctls ---"
    for key in \
        net.core.rmem_default \
        net.core.rmem_max \
        net.core.wmem_default \
        net.core.wmem_max \
        net.core.netdev_max_backlog \
        net.core.somaxconn \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.udp_rmem_min \
        net.ipv4.udp_wmem_min \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.tcp_congestion_control \
        net.ipv4.tcp_moderate_rcvbuf
    do
        printf "%s=" "$key"
        kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- sh -c "cat /proc/sys/${key//./\/}" 2>/dev/null || echo "N/A"
    done
    echo ""
    echo "--- Socket memory counters ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/sockstat 2>/dev/null || true
    echo ""
    kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/sockstat6 2>/dev/null || true
    echo ""
    echo "--- NIC queue/tuning (receiver node) ---"
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- sh -c 'for d in /sys/class/net/*/queues/rx-*/rps_cpus; do echo "$d: $(cat "$d")"; done' 2>/dev/null || true
    kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- sh -c 'for d in /sys/class/net/*/queues/rx-*/rps_flow_cnt; do echo "$d: $(cat "$d")"; done' 2>/dev/null || true
} > "$RESULTS_DIR/kernel-env.txt" 2>&1
log "  Kernel env captured"

# --- CAPTURE eBPF MAP STATE (PRE-TEST) ---
log "[5/8] Capturing eBPF map state (pre-test)..."
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
log "  eBPF maps captured ($(grep -c "^[0-9]" "$RESULTS_DIR/ebpf-maps-pretest.txt" 2>/dev/null || echo 0) entries)"

# --- CAPTURE SOFTIRQ BASELINE ---
log "[6/8] Capturing softirq baseline..."
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/net/softnet_stat > "$RESULTS_DIR/softirq-before.txt"
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/softirqs > "$RESULTS_DIR/proc-softirqs-before.txt" 2>/dev/null || true
kubectl exec softirq-monitor -n "$NAMESPACE" -- cat /host/proc/interrupts > "$RESULTS_DIR/proc-interrupts-before.txt" 2>/dev/null || true
log "  Softirq baseline captured"

# --- DEPLOY CLIENTS AND RUN TEST ---
log "[7/8] Deploying $CLIENT_REPLICAS client pods (duration=${DURATION}s)..."
sed "s|REGISTRY|$REGISTRY|g; s|replicas: 20|replicas: $CLIENT_REPLICAS|; s|--conns=16|--conns=${CONNS_PER_POD}|; s|duration=120s|duration=${DURATION}s|; s|--payload=4096|--payload=${PAYLOAD_BYTES}|; s|--qps=0|--qps=${QPS_PER_CONN}|" \
    "$SCRIPT_DIR/deploy/client.yaml" | kubectl apply -f -
kubectl rollout status deployment/tcp-client -n "$NAMESPACE" --timeout=180s
log "  All client pods ready — test started at $(date -u)"

# --- BACKGROUND: ring-buffer pressure monitor (every 30s) ---
(
    RBUF_END=$(($(date +%s) + DURATION + 5))
    while [[ $(date +%s) -lt $RBUF_END ]]; do
        {
            echo "=== $(date -u) ==="
            kubectl exec softirq-monitor -n "$NAMESPACE" -- nsenter -t 1 -m -- \
                bpftool map show -j 2>/dev/null | \
                jq '[.[] | select(.type == "ringbuf" or .type == "perf_event_array") | {id, name, type, max_entries, bytes_memlock}]' 2>/dev/null || true
        } >> "$RESULTS_DIR/ringbuf-pressure.txt" 2>&1
        sleep 30
    done
) &
PRESSURE_PID=$!

# --- BACKGROUND: Retina + node resource usage (every 30s) ---
(
    RES_END=$(($(date +%s) + DURATION + 5))
    while [[ $(date +%s) -lt $RES_END ]]; do
        {
            echo "=== $(date -u) ==="
            echo "--- retina pods ---"
            kubectl top pods -n kube-system -l k8s-app=retina 2>/dev/null || echo "  (metrics-server not available or no retina)"
            echo "--- nodes ---"
            kubectl top nodes 2>/dev/null || echo "  (metrics-server not available)"
        } >> "$RESULTS_DIR/resource-usage.txt" 2>&1
        sleep 30
    done
) &
RESOURCE_PID=$!

# Monitor throughput during test, sampling every 5s
log ""
log "  Test running... sampling throughput every 5s:"
THROUGHPUT_LOG="$RESULTS_DIR/throughput-live.txt"
> "$THROUGHPUT_LOG"

POLL_END=$(($(date +%s) + DURATION + 10))
SAMPLE_COUNT=0
while [[ $(date +%s) -lt $POLL_END ]]; do
    LINE=$(kubectl logs "$RECV_POD" -n "$NAMESPACE" --tail=1 2>/dev/null || echo "N/A")
    TS=$(date -u +"%H:%M:%S")
    log "  [$TS] $LINE"
    echo "[$TS] $LINE" >> "$THROUGHPUT_LOG"
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    sleep 5
done
log "  Test complete — $SAMPLE_COUNT throughput samples collected"

# Stop background monitors
kill $PRESSURE_PID $RESOURCE_PID 2>/dev/null || true
wait $PRESSURE_PID $RESOURCE_PID 2>/dev/null || true

# --- COLLECT ALL POST-TEST RESULTS ---
log ""
log "[8/8] Collecting final results..."

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
log "  Saving receiver logs..."
kubectl logs "$RECV_POD" -n "$NAMESPACE" > "$RESULTS_DIR/receiver-full.log" 2>&1

# Client logs (all pods, last 10 lines each)
log "  Saving client logs..."
{
    for POD in $(kubectl get pods -n "$NAMESPACE" -l app=tcp-client -o jsonpath='{.items[*].metadata.name}'); do
        echo "=== $POD ==="
        kubectl logs "$POD" -n "$NAMESPACE" --tail=10 2>/dev/null || echo "  (no logs)"
        echo ""
    done
} > "$RESULTS_DIR/client-all.log" 2>&1

# Retina logs post-test (full)
if [[ -n "$RETINA_POD" ]]; then
    log "  Saving Retina logs..."
    kubectl logs "$RETINA_POD" -n kube-system > "$RESULTS_DIR/retina-posttest.log" 2>&1
fi

# --- COMPUTE SUMMARY ---
log "  Computing summary..."
{
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║ TEST SUMMARY: $CLUSTER_NAME"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Cluster: $CLUSTER_NAME"
    echo "Date: $(date -u)"
    echo "Duration: ${DURATION}s"
    echo "Client replicas: $CLIENT_REPLICAS"
    echo "Conns per pod: $CONNS_PER_POD"
    echo "Total TCP streams: $((CLIENT_REPLICAS * CONNS_PER_POD))"
    echo "Payload size: ${PAYLOAD_BYTES} bytes"
    echo "QPS per connection: $QPS_PER_CONN (0 means unlimited)"
    echo "Receiver node: $RECV_NODE"
    echo "Throughput samples: $SAMPLE_COUNT (5s interval)"
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
    echo ""
    echo "=== KERNEL NET TUNABLE SNAPSHOT ==="
    grep -E '^net\.|^---|^Kernel|^Date|^Node' "$RESULTS_DIR/kernel-env.txt" 2>/dev/null || echo "  Missing kernel-env.txt"
    echo ""
    echo "=== RETINA RESOURCE USAGE (peak during test) ==="
    if [[ -f "$RESULTS_DIR/resource-usage.txt" ]]; then
        grep -A3 'retina' "$RESULTS_DIR/resource-usage.txt" 2>/dev/null | grep -v '^=\|^--' | sort -k3 -rn | head -5 || echo "  No retina resource data"
    else
        echo "  resource-usage.txt not found"
    fi
    echo ""
    echo "=== RING BUFFER PRESSURE (peak during test) ==="
    if [[ -f "$RESULTS_DIR/ringbuf-pressure.txt" ]]; then
        python3 -c "
import json, sys, re
data = open('$RESULTS_DIR/ringbuf-pressure.txt').read()
blocks = re.findall(r'\\[.*?\\]', data, re.DOTALL)
for b in blocks:
    try:
        maps = json.loads(b)
        for m in maps:
            print(f\"  id={m.get('id','?')} name={m.get('name','?')} type={m.get('type','?')} max_entries={m.get('max_entries','?')} bytes_memlock={m.get('bytes_memlock','?')}\")
    except: pass
" 2>/dev/null | sort -u | head -20 || echo "  No ring buffer pressure data"
    else
        echo "  ringbuf-pressure.txt not found"
    fi
} > "$RESULTS_DIR/summary.txt" 2>&1

# Print summary to stdout
log ""
cat "$RESULTS_DIR/summary.txt"

# --- CLEANUP ---
log ""
log "Cleaning up test pods..."
kubectl delete deployment tcp-client -n "$NAMESPACE" --ignore-not-found
kubectl delete deployment tcp-receiver -n "$NAMESPACE" --ignore-not-found
kubectl delete service tcp-receiver -n "$NAMESPACE" --ignore-not-found
kubectl delete pod softirq-monitor -n "$NAMESPACE" --ignore-not-found

log ""
log "═══════════════════════════════════════"
log "Results saved to: $RESULTS_DIR/"
log "═══════════════════════════════════════"
ls "$RESULTS_DIR/"
echo ""
echo "Done: $CLUSTER_NAME"
