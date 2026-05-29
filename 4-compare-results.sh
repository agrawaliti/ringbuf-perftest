#!/bin/bash
set -euo pipefail

# Compare results across all 3 variants and all scenarios.
#
# Usage (new — results root from 8-cross-variant-scenarios.sh):
#   ./4-compare-results.sh <results-root>
#
# Usage (legacy — individual cluster names from /tmp):
#   ./4-compare-results.sh <baseline-cluster> <perfarray-cluster> <ringbuf-cluster>

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# ── Detect mode ──────────────────────────────────────────────────────────────
if [[ $# -eq 1 && -d "$1" ]]; then
    RESULTS_ROOT="$1"
    # Discover variant dirs: base / pa / rb
    BASE_DIR="${RESULTS_ROOT}/base"
    PA_DIR="${RESULTS_ROOT}/pa"
    RB_DIR="${RESULTS_ROOT}/rb"
    MODE="root"
elif [[ $# -eq 3 ]]; then
    BASELINE="$1"; PERFARRAY="$2"; RINGBUF="$3"
    MODE="legacy"
else
    echo "Usage (new): $0 <results-root>"
    echo "Usage (old): $0 <baseline-cluster> <perfarray-cluster> <ringbuf-cluster>"
    exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

# Extract steady-state median Gb/s from a throughput-live.txt
# (median of all readings, excluding first 10% as ramp-up)
median_throughput() {
    local file="$1"
    [[ -f "$file" ]] || { echo "N/A"; return; }
    python3 - "$file" <<'PYEOF'
import sys, re
lines = open(sys.argv[1]).readlines()
vals = []
for l in lines:
    m = re.search(r'throughput=([\d.]+)\s*Gb/s', l)
    if m:
        vals.append(float(m.group(1)))
if not vals:
    print("N/A"); sys.exit()
skip = max(1, len(vals) // 10)   # skip first 10% (ramp-up)
vals = sorted(vals[skip:])
mid = len(vals) // 2
print(f"{vals[mid]:.2f}" if vals else "N/A")
PYEOF
}

# Extract peak Gb/s
peak_throughput() {
    local file="$1"
    [[ -f "$file" ]] || { echo "N/A"; return; }
    grep -oP '[\d.]+(?=\s*Gb/s)' "$file" 2>/dev/null | sort -rn | head -1 || echo "N/A"
}

# Extract stddev of steady-state readings
stddev_throughput() {
    local file="$1"
    [[ -f "$file" ]] || { echo "N/A"; return; }
    python3 - "$file" <<'PYEOF'
import sys, re, math
lines = open(sys.argv[1]).readlines()
vals = []
for l in lines:
    m = re.search(r'throughput=([\d.]+)\s*Gb/s', l)
    if m:
        vals.append(float(m.group(1)))
if len(vals) < 3:
    print("N/A"); sys.exit()
skip = max(1, len(vals) // 10)
vals = vals[skip:]
mean = sum(vals) / len(vals)
sd = math.sqrt(sum((x - mean)**2 for x in vals) / len(vals))
print(f"{sd:.3f}")
PYEOF
}

# Extract softirq drops from summary.txt
softirq_drops() {
    local summary="$1"
    [[ -f "$summary" ]] || { echo "N/A"; return; }
    grep -oP '(?<=TOTAL softirq drops: )\d+' "$summary" 2>/dev/null | tail -1 || echo "0"
}

# Extract peak Retina CPU from resource-usage.txt (retina-agent pods only)
retina_cpu_peak() {
    local file="$1"
    [[ -f "$file" ]] || { echo "N/A"; return; }
    # Only look at retina-agent-* pod lines (not node CPU lines)
    grep 'retina-agent-' "$file" 2>/dev/null | \
        awk '{print $2}' | grep -oP '^\d+(?=m)' | sort -rn | head -1 | \
        awk '{print $1"m"}' || echo "N/A"
}

# ── ROOT MODE: multi-scenario per-variant comparison ─────────────────────────
if [[ "$MODE" == "root" ]]; then

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Ring Buffer vs Perf Array — Real-Life Scenario Comparison                      ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Results root: ${CYAN}${RESULTS_ROOT}${NC}"
    echo ""

    # Discover all scenarios (union across all 3 variant dirs)
    ALL_SCENARIOS=()
    for vdir in "$BASE_DIR" "$PA_DIR" "$RB_DIR"; do
        [[ -d "$vdir" ]] || continue
        # 7-real-life-scenarios.sh nests results as <vdir>/<cluster>/<timestamp>/<scenario>/
        # or directly as <vdir>/<scenario>/ — detect which layout
        for d in "$vdir"/*/; do
            [[ -d "$d" ]] || continue
            # Check if this is a scenario dir (has summary.txt or throughput-live.txt)
            if [[ -f "${d}summary.txt" || -f "${d}throughput-live.txt" ]]; then
                sc="$(basename "$d")"
                # avoid duplicates
                if ! printf '%s\n' "${ALL_SCENARIOS[@]:-}" | grep -qx "$sc"; then
                    ALL_SCENARIOS+=("$sc")
                fi
            else
                # one level deeper (cluster/timestamp/scenario or cluster/timestamp/scenario/cluster)
                for d2 in "$d"*/; do
                    [[ -d "$d2" ]] || continue
                    if [[ -f "${d2}summary.txt" || -f "${d2}throughput-live.txt" ]]; then
                        sc="$(basename "$d2")"
                        if ! printf '%s\n' "${ALL_SCENARIOS[@]:-}" | grep -qx "$sc"; then
                            ALL_SCENARIOS+=("$sc")
                        fi
                    else
                        # two or three levels deeper
                        for d3 in "$d2"*/; do
                            [[ -d "$d3" ]] || continue
                            if [[ -f "${d3}summary.txt" || -f "${d3}throughput-live.txt" ]]; then
                                sc="$(basename "$d2")"
                                if ! printf '%s\n' "${ALL_SCENARIOS[@]:-}" | grep -qx "$sc"; then
                                    ALL_SCENARIOS+=("$sc")
                                fi
                                break
                            else
                                # three levels deeper: d2=timestamp/ d3=scenario/ d4=cluster/
                                for d4 in "$d3"*/; do
                                    [[ -d "$d4" ]] || continue
                                    if [[ -f "${d4}summary.txt" || -f "${d4}throughput-live.txt" ]]; then
                                        sc="$(basename "$d3")"
                                        if ! printf '%s\n' "${ALL_SCENARIOS[@]:-}" | grep -qx "$sc"; then
                                            ALL_SCENARIOS+=("$sc")
                                        fi
                                        break
                                    fi
                                done
                            fi
                        done
                    fi
                done
            fi
        done
    done

    # Helper to find the result dir for a variant + scenario
    find_result_dir() {
        local vdir="$1"
        local scenario="$2"
        [[ -d "$vdir" ]] || { echo ""; return; }
        # direct layout
        if [[ -f "${vdir}/${scenario}/summary.txt" || -f "${vdir}/${scenario}/throughput-live.txt" ]]; then
            echo "${vdir}/${scenario}"
            return
        fi
        # nested layout: find scenario dir, then look for data inside (possibly one more level)
        local found
        found=$(find "$vdir" -maxdepth 4 -type d -name "$scenario" 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            # Check if data is directly in scenario dir or one level deeper
            if [[ -f "${found}/summary.txt" || -f "${found}/throughput-live.txt" ]]; then
                echo "$found"
            else
                # Data is in a subdirectory (e.g. scenario/cluster-name/)
                local inner
                inner=$(find "$found" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
                echo "${inner:-$found}"
            fi
        else
            echo ""
        fi
    }

    # ── Per-scenario table ────────────────────────────────────────────────────
    printf "\n${BOLD}%-22s  %-12s %-8s %-8s  |  %-12s %-8s %-8s  |  %-12s %-8s %-8s  |  %-6s %-6s${NC}\n" \
        "Scenario" \
        "Base-med" "peak" "±σ" \
        "PA-med" "peak" "±σ" \
        "RB-med" "peak" "±σ" \
        "PA-loss" "RB-loss"
    printf "%-22s  %-12s %-8s %-8s  |  %-12s %-8s %-8s  |  %-12s %-8s %-8s  |  %-6s %-6s\n" \
        "$(printf '%0.s-' {1..22})" \
        "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})" \
        "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})" \
        "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})" \
        "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})"

    for sc in "${ALL_SCENARIOS[@]:-}"; do
        bdir=$(find_result_dir "$BASE_DIR" "$sc")
        pdir=$(find_result_dir "$PA_DIR"  "$sc")
        rdir=$(find_result_dir "$RB_DIR"  "$sc")

        b_med=$(median_throughput "${bdir}/throughput-live.txt")
        b_peak=$(peak_throughput  "${bdir}/throughput-live.txt")
        b_sd=$(stddev_throughput  "${bdir}/throughput-live.txt")

        p_med=$(median_throughput "${pdir}/throughput-live.txt")
        p_peak=$(peak_throughput  "${pdir}/throughput-live.txt")
        p_sd=$(stddev_throughput  "${pdir}/throughput-live.txt")

        r_med=$(median_throughput "${rdir}/throughput-live.txt")
        r_peak=$(peak_throughput  "${rdir}/throughput-live.txt")
        r_sd=$(stddev_throughput  "${rdir}/throughput-live.txt")

        # Throughput loss vs baseline (%)
        pa_loss="N/A"; rb_loss="N/A"
        if [[ "$b_med" != "N/A" && "$p_med" != "N/A" ]]; then
            pa_loss=$(python3 -c "print(f\"{(($b_med-$p_med)/$b_med*100):.1f}%\")")
        fi
        if [[ "$b_med" != "N/A" && "$r_med" != "N/A" ]]; then
            rb_loss=$(python3 -c "print(f\"{(($b_med-$r_med)/$b_med*100):.1f}%\")")
        fi

        printf "%-22s  %-12s %-8s %-8s  |  %-12s %-8s %-8s  |  %-12s %-8s %-8s  |  %-6s %-6s\n" \
            "$sc" \
            "${b_med} Gb/s" "$b_peak" "±${b_sd}" \
            "${p_med} Gb/s" "$p_peak" "±${p_sd}" \
            "${r_med} Gb/s" "$r_peak" "±${r_sd}" \
            "$pa_loss" "$rb_loss"
    done

    # ── Softirq drops table ───────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Softirq drops:${NC}"
    printf "%-22s  %-10s %-10s %-10s\n" "Scenario" "Baseline" "PerfArray" "RingBuf"
    printf "%-22s  %-10s %-10s %-10s\n" "$(printf '%0.s-' {1..22})" "--------" "---------" "-------"
    for sc in "${ALL_SCENARIOS[@]:-}"; do
        bdir=$(find_result_dir "$BASE_DIR" "$sc")
        pdir=$(find_result_dir "$PA_DIR"  "$sc")
        rdir=$(find_result_dir "$RB_DIR"  "$sc")
        bd=$(softirq_drops "${bdir}/summary.txt")
        pd=$(softirq_drops "${pdir}/summary.txt")
        rd=$(softirq_drops "${rdir}/summary.txt")
        printf "%-22s  %-10s %-10s %-10s\n" "$sc" "$bd" "$pd" "$rd"
    done

    # ── Retina resource usage table ───────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Retina peak CPU during test (from kubectl top):${NC}"
    printf "%-22s  %-12s %-12s\n" "Scenario" "PerfArray" "RingBuf"
    printf "%-22s  %-12s %-12s\n" "$(printf '%0.s-' {1..22})" "----------" "--------"
    for sc in "${ALL_SCENARIOS[@]:-}"; do
        pdir=$(find_result_dir "$PA_DIR" "$sc")
        rdir=$(find_result_dir "$RB_DIR" "$sc")
        pc=$(retina_cpu_peak "${pdir}/resource-usage.txt")
        rc=$(retina_cpu_peak "${rdir}/resource-usage.txt")
        printf "%-22s  %-12s %-12s\n" "$sc" "$pc" "$rc"
    done

    echo ""
    echo -e "Full results: ${CYAN}${RESULTS_ROOT}${NC}"
    echo -e "Logs:         ${CYAN}${RESULTS_ROOT}/logs/${NC}"

# ── LEGACY MODE: 3 cluster names from /tmp ───────────────────────────────────
else
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

    for CLUSTER in "$BASELINE" "$PERFARRAY" "$RINGBUF"; do
        FILE="/tmp/${CLUSTER}_results.txt"
        PEAK=$(grep -oP '[\d.]+ Gb/s' "$FILE" 2>/dev/null | sort -rn | head -1 || echo "N/A")
        DROPS=$(grep "drops" "$FILE" 2>/dev/null | awk '{sum += $2} END {printf "%d", sum}' || echo "0")
        if [[ "$CLUSTER" == "$BASELINE" ]]; then
            BASELINE_PEAK="$PEAK"; BASELINE_DROPS="$DROPS"
        elif [[ "$CLUSTER" == "$PERFARRAY" ]]; then
            PERFARRAY_PEAK="$PEAK"; PERFARRAY_DROPS="$DROPS"
        else
            RINGBUF_PEAK="$PEAK"; RINGBUF_DROPS="$DROPS"
        fi
    done

    printf "%-20s %-15s %-15s %-15s\n" "Peak throughput" "${BASELINE_PEAK:-N/A}" "${PERFARRAY_PEAK:-N/A}" "${RINGBUF_PEAK:-N/A}"
    printf "%-20s %-15s %-15s %-15s\n" "Total drops" "${BASELINE_DROPS:-0}" "${PERFARRAY_DROPS:-0}" "${RINGBUF_DROPS:-0}"
fi

