#!/bin/bash
set -euo pipefail

# Parallel cross-variant real-life scenario runner.
#
# Creates 3 AKS clusters simultaneously (baseline / perf-array / ring-buffer),
# installs Retina on pa+rb in parallel, then runs all real-life scenarios on
# every cluster concurrently. Collects results and prints a per-scenario
# comparison table.
#
# Usage:
#   ./8-cross-variant-scenarios.sh [duration_secs] [scenario|all] [results_root]
#
# Examples:
#   ./8-cross-variant-scenarios.sh 300 all
#   ./8-cross-variant-scenarios.sh 300 low-load /tmp/my-results
#
# Environment overrides:
#   SUBSCRIPTION   Azure subscription ID (default: set in script)
#   LOCATION       Azure region (default: canadacentral)
#   PREFIX         Cluster name prefix (default: rbt)
#   REGISTRY       ACR to pull images from (default: acndev.azurecr.io)

DURATION="${1:-300}"
SCENARIO="${2:-all}"
TIMESTAMP=$(date +%m%d%H%M)
RESULTS_ROOT="${3:-$(pwd)/results/rl-${TIMESTAMP}}"

SUBSCRIPTION="${SUBSCRIPTION:-37deca37-c375-4a14-b90a-043849bd2bf1}"
LOCATION="${LOCATION:-canadacentral}"
VM_SIZE_SYSTEM="${VM_SIZE_SYSTEM:-Standard_D4s_v3}"
VM_SIZE_32CORE="${VM_SIZE_32CORE:-Standard_D32s_v3}"
K8S_VERSION="1.34"
PREFIX="${PREFIX:-rbt}"
REGISTRY="${REGISTRY:-acndev.azurecr.io}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${RESULTS_ROOT}/logs"
mkdir -p "$LOG_DIR"

# ── Colours for readability ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()       { echo -e "[$(date -u +%H:%M:%S)] $*"; }
log_ok()    { echo -e "[$(date -u +%H:%M:%S)] ${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "[$(date -u +%H:%M:%S)] ${YELLOW}⚠${NC} $*"; }
log_err()   { echo -e "[$(date -u +%H:%M:%S)] ${RED}✗${NC} $*" >&2; }
log_phase() { echo -e "\n[$(date -u +%H:%M:%S)] ${BOLD}${CYAN}══ $* ══${NC}"; }

# ── Cluster definitions ──────────────────────────────────────────────────────
declare -A RETINA_MODE
RETINA_MODE[base]="none"
RETINA_MODE[pa]="disabled"
RETINA_MODE[rb]="enabled"
ORDER=(base pa rb)
LABEL_base="Baseline (no Retina)"
LABEL_pa="Perf Array"
LABEL_rb="Ring Buffer"

# Derived names
CLUSTER_base="${PREFIX}-base-${TIMESTAMP}"
CLUSTER_pa="${PREFIX}-pa-${TIMESTAMP}"
CLUSTER_rb="${PREFIX}-rb-${TIMESTAMP}"
RG_base="${CLUSTER_base}-rg"
RG_pa="${CLUSTER_pa}-rg"
RG_rb="${CLUSTER_rb}-rg"
KUBE_base="/tmp/kube-${CLUSTER_base}.yaml"
KUBE_pa="/tmp/kube-${CLUSTER_pa}.yaml"
KUBE_rb="/tmp/kube-${CLUSTER_rb}.yaml"

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Ring Buffer vs Perf Array — Parallel Real-Life Test        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "Subscription : $SUBSCRIPTION"
log "Location     : $LOCATION"
log "Timestamp    : $TIMESTAMP"
log "Duration     : ${DURATION}s per scenario"
log "Scenario(s)  : $SCENARIO"
log "Results root : $RESULTS_ROOT"
log "Log dir      : $LOG_DIR"
echo ""

az account set --subscription "$SUBSCRIPTION"
log_ok "Subscription set"

# ── Helper: create one cluster (called in background) ────────────────────────
create_cluster() {
    local variant="$1"
    local logfile="${LOG_DIR}/${variant}-create.log"

    local clname; clname="$(eval echo "\${CLUSTER_${variant}}")"
    local rgname; rgname="$(eval echo "\${RG_${variant}}")"

    {
        echo "[$(date -u +%H:%M:%S)] === Creating cluster: $clname (variant=$variant) ==="
        az group create --name "$rgname" --location "$LOCATION" \
            --subscription "$SUBSCRIPTION" -o none

        echo "[$(date -u +%H:%M:%S)] Creating AKS cluster..."
        az aks create \
            --subscription "$SUBSCRIPTION" \
            --resource-group "$rgname" \
            --name "$clname" \
            --location "$LOCATION" \
            --kubernetes-version "$K8S_VERSION" \
            --node-count 3 \
            --node-vm-size "$VM_SIZE_SYSTEM" \
            --network-plugin azure \
            --network-plugin-mode overlay \
            --generate-ssh-keys \
            --tier standard \
            --no-wait \
            -o none
        echo "[$(date -u +%H:%M:%S)] Cluster creation submitted, waiting..."
        az aks wait --resource-group "$rgname" --name "$clname" --created --interval 15 --timeout 900

        echo "[$(date -u +%H:%M:%S)] Adding np32core nodepool (2× Standard_D32s_v3)..."
        az aks nodepool add \
            --subscription "$SUBSCRIPTION" \
            --resource-group "$rgname" \
            --cluster-name "$clname" \
            --name np32core \
            --node-count 2 \
            --node-vm-size "$VM_SIZE_32CORE" \
            --mode User \
            -o none

        echo "[$(date -u +%H:%M:%S)] Attaching ACR ($REGISTRY)..."
        az aks update \
            --subscription "$SUBSCRIPTION" \
            --resource-group "$rgname" \
            --name "$clname" \
            --attach-acr "${REGISTRY%%.*}" \
            -o none 2>/dev/null || echo "  (ACR attach skipped)"

        echo "[$(date -u +%H:%M:%S)] Fetching kubeconfig -> $(eval echo "\${KUBE_${variant}}")"
        az aks get-credentials \
            --subscription "$SUBSCRIPTION" \
            --resource-group "$rgname" \
            --name "$clname" \
            --file "$(eval echo "\${KUBE_${variant}}")" \
            --overwrite-existing

        echo "[$(date -u +%H:%M:%S)] DONE: $clname"
    } 2>&1 | tee "$logfile"
}

# ── Helper: install Retina (called in background) ────────────────────────────
setup_retina() {
    local variant="$1"
    local mode="${RETINA_MODE[$variant]}"
    local clname; clname="$(eval echo "\${CLUSTER_${variant}}")"
    local rgname; rgname="$(eval echo "\${RG_${variant}}")"
    local kube; kube="$(eval echo "\${KUBE_${variant}}")"
    local logfile="${LOG_DIR}/${variant}-retina.log"

    {
        if [[ "$mode" == "none" ]]; then
            echo "[$(date -u +%H:%M:%S)] $clname: skipping Retina (baseline)"
            exit 0
        fi
        echo "[$(date -u +%H:%M:%S)] $clname: installing Retina (packetParserRingBuffer=$mode)..."
        KUBECONFIG="$kube" "$SCRIPT_DIR/2-setup-retina.sh" "$clname" "$rgname" "$mode"
        echo "[$(date -u +%H:%M:%S)] DONE: Retina on $clname"
    } 2>&1 | tee "$logfile"
}

# ── Helper: run all scenarios on one cluster (called in background) ───────────
run_scenarios() {
    local variant="$1"
    local clname; clname="$(eval echo "\${CLUSTER_${variant}}")"
    local rgname; rgname="$(eval echo "\${RG_${variant}}")"
    local kube; kube="$(eval echo "\${KUBE_${variant}}")"
    local out_root="${RESULTS_ROOT}/${variant}"
    local logfile="${LOG_DIR}/${variant}-scenarios.log"

    mkdir -p "$out_root"
    {
        echo "[$(date -u +%H:%M:%S)] === Running scenarios on $clname (variant=$variant) ==="
        KUBECONFIG_FILE="$kube" \
        "$SCRIPT_DIR/7-real-life-scenarios.sh" \
            "$clname" \
            "$rgname" \
            "$SCENARIO" \
            "$DURATION" \
            "$out_root"
        echo "[$(date -u +%H:%M:%S)] === All scenarios complete on $clname ==="
    } 2>&1 | tee "$logfile"
}

# ── PHASE 1: Create all 3 clusters in parallel ───────────────────────────────
log_phase "PHASE 1 — Creating 3 clusters in parallel"
log "  base : ${CLUSTER_base}  RG: ${RG_base}"
log "  pa   : ${CLUSTER_pa}   RG: ${RG_pa}"
log "  rb   : ${CLUSTER_rb}   RG: ${RG_rb}"
echo ""

CREATE_PIDS=()
for v in "${ORDER[@]}"; do
    log "  Launching creation: $v  -> ${LOG_DIR}/${v}-create.log"
    create_cluster "$v" &
    CREATE_PIDS+=($!)
done

FAIL=0
for i in "${!ORDER[@]}"; do
    v="${ORDER[$i]}"
    pid="${CREATE_PIDS[$i]}"
    log "  Waiting for $v cluster (pid=$pid)..."
    if wait "$pid"; then
        log_ok "  $v cluster ready"
    else
        log_err "  $v cluster creation FAILED — check ${LOG_DIR}/${v}-create.log"
        FAIL=1
    fi
done

if [[ $FAIL -ne 0 ]]; then
    log_err "One or more clusters failed to create. Aborting."
    exit 1
fi
log_ok "All 3 clusters created"

# ── PHASE 2: Install Retina in parallel (pa + rb; base skipped) ──────────────
log_phase "PHASE 2 — Installing Retina (pa=disabled, rb=enabled) in parallel"

RETINA_PIDS=()
for v in "${ORDER[@]}"; do
    log "  Launching Retina setup: $v (mode=${RETINA_MODE[$v]})  -> ${LOG_DIR}/${v}-retina.log"
    setup_retina "$v" &
    RETINA_PIDS+=($!)
done

FAIL=0
for i in "${!ORDER[@]}"; do
    v="${ORDER[$i]}"
    pid="${RETINA_PIDS[$i]}"
    log "  Waiting for $v Retina setup (pid=$pid)..."
    if wait "$pid"; then
        log_ok "  $v Retina setup complete"
    else
        log_err "  $v Retina setup FAILED — check ${LOG_DIR}/${v}-retina.log"
        FAIL=1
    fi
done

if [[ $FAIL -ne 0 ]]; then
    log_err "One or more Retina setups failed. Aborting."
    exit 1
fi
log_ok "Retina setup complete on all clusters"

# ── PHASE 3: Run scenarios on all 3 clusters in parallel ─────────────────────
log_phase "PHASE 3 — Running scenarios on all 3 clusters in parallel"
log "  Each cluster runs: $SCENARIO (${DURATION}s/scenario)"
log "  Results root: $RESULTS_ROOT"
echo ""
log "  Live logs:"
for v in "${ORDER[@]}"; do
    log "    tail -f ${LOG_DIR}/${v}-scenarios.log"
done
echo ""

SCENARIO_PIDS=()
for v in "${ORDER[@]}"; do
    log "  Launching scenarios: $v  -> ${LOG_DIR}/${v}-scenarios.log"
    run_scenarios "$v" &
    SCENARIO_PIDS+=($!)
done

FAIL=0
for i in "${!ORDER[@]}"; do
    v="${ORDER[$i]}"
    pid="${SCENARIO_PIDS[$i]}"
    log "  Waiting for $v scenarios (pid=$pid)..."
    if wait "$pid"; then
        log_ok "  $v scenarios complete"
    else
        log_err "  $v scenarios FAILED — check ${LOG_DIR}/${v}-scenarios.log"
        FAIL=1
    fi
done

if [[ $FAIL -ne 0 ]]; then
    log_warn "One or more scenario runs had failures — partial results may still be available"
fi

# ── PHASE 4: Compare results ──────────────────────────────────────────────────
log_phase "PHASE 4 — Comparing results"
"$SCRIPT_DIR/4-compare-results.sh" "$RESULTS_ROOT" || true

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Run Complete                                               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
log "Results root : $RESULTS_ROOT"
log "Logs         : $LOG_DIR"
echo ""
log "To tear down all clusters:"
for v in "${ORDER[@]}"; do
    rgname="$(eval echo "\${RG_${v}}")"
    echo "  az group delete --name $rgname --yes --no-wait"
done
echo ""
log "To re-compare results later:"
echo "  ./4-compare-results.sh $RESULTS_ROOT"
