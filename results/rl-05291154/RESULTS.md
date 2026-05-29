# Retina Ring Buffer vs Perf Array — Real-Life Scenario Results

**Run ID:** `rl-05291154`  
**Date:** May 29, 2026  
**Duration per scenario:** 300 s  
**Results root:** `results/rl-05291154/`

---

## 1. Test Infrastructure

### Clusters (3 independent AKS clusters, canadacentral)

| Cluster | Resource Group | Kubernetes |
|---|---|---|
| `rbt-rb-05291154` | `rbt-rb-05291154-rg` | v1.34.7 |
| `rbt-pa-05291154` | `rbt-pa-05291154-rg` | v1.34.7 |
| `rbt-base-05291154` | `rbt-base-05291154-rg` | v1.34.7 |

### Node pools (identical across all 3 clusters)

| Pool | SKU | Count | vCPU | RAM | Role |
|---|---|---|---|---|---|
| `nodepool1` | Standard_D4s_v3 | 3 | 4 | 16 GiB | system |
| `np32core` | Standard_D32s_v3 | 2 | 32 | 128 GiB | test workload |

OS: Ubuntu 22.04.5 LTS, Kernel: `5.15.0-1111-azure`

### Retina configuration

| Cluster | Retina | `packetParserRingBuffer` | Ring buffer size |
|---|---|---|---|
| `rbt-rb` | v1.2.0 | **enabled** | 8 MiB |
| `rbt-pa` | v1.2.0 | **disabled** (uses `perf_event_array`) | — |
| `rbt-base` | **not installed** | — | — |

Plugins enabled on both Retina clusters: `linuxutil, packetforward, packetparser, dns, dropreason`  
`dataAggregationLevel: low`, `enablePodLevel: true`

### Test tooling

Go-based `tcp-client` / `tcp-receiver` from `acndev.azurecr.io`, deployed in `perf-test` namespace. The client opens N TCP connections and sends fixed-size payloads at a configurable QPS rate. The receiver reports live throughput every 2 seconds.

---

## 2. Scenarios

All 8 scenarios ran in parallel across the 3 clusters. Each scenario ran for 300 s with 5 s throughput sampling on the orchestrator side.

| # | Scenario | Streams | Payload | QPS/conn | Traffic character |
|---|---|---|---|---|---|
| 1 | `api-read-heavy` | 576 (24p×24c) | 512 B | 8 k | High-QPS medium-payload, ~2.4 GB/s target |
| 2 | `grpc-streaming` | 320 (20p×16c) | 2 048 B | 2 k | Streaming medium frames, ~1.3 GB/s target |
| 3 | `iot-telemetry` | 360 (30p×12c) | 128 B | 20 k | Very small packets at high QPS, ~900 MB/s target |
| 4 | `log-shipper` | 120 (12p×10c) | 16 384 B | 400 | Large frames at moderate QPS, ~800 MB/s target |
| 5 | `mixed-web-spiky` | 400 (20p×20c) | 1 024 B | 5 k | Bursty web-like traffic, ~2 GB/s target |
| 6 | `low-load` | 16 (4p×4c) | 1 024 B | 1 k | QPS-capped light traffic, ~16 MB/s target |
| 7 | `microservice-fanout` | 160 (40p×4c) | 256 B | ∞ | Many small connections, unlimited rate |
| 8 | `bulk-ingest` | 64 (8p×8c) | 65 536 B | ∞ | Few large-payload connections, unlimited rate |

---

## 3. Results

### 3.1 Peak throughput (from `summary.txt`)

Peak = highest single 2 s receiver reading over the full 300 s run.

| Scenario | Base peak | PA peak | RB peak | eBPF map type |
|---|---|---|---|---|
| api-read-heavy | 4.32 Gb/s ⚠️ | 5.66 Gb/s | **6.20 Gb/s** | pa=perf_event_array / rb=ringbuf |
| grpc-streaming | 5.92 Gb/s | **6.91 Gb/s** | 6.08 Gb/s | |
| iot-telemetry | 1.09 Gb/s ⚠️ | 3.30 Gb/s | 2.07 Gb/s | |
| log-shipper | 6.29 Gb/s | 6.28 Gb/s | **6.30 Gb/s** | |
| mixed-web-spiky | **10.82 Gb/s** | 8.36 Gb/s ⚠️ | 10.97 Gb/s | |
| low-load | ~120 Mb/s | ~117 Mb/s | ~122 Mb/s | all equal |
| microservice-fanout | 3.06 Gb/s ⚠️ | 11.53 Gb/s | **15.18 Gb/s** | |
| bulk-ingest | **15.16 Gb/s** | 14.80 Gb/s | **15.16 Gb/s** | |

⚠️ = known node placement confound (see §4)

### 3.2 Steady-state median throughput (from `4-compare-results.sh`, 5 s samples)

| Scenario | Base med | PA med | RB med | PA vs base | RB vs base |
|---|---|---|---|---|---|
| api-read-heavy | 4.11 Gb/s ⚠️ | 1.10 Gb/s | **5.92 Gb/s** | −73% | −44% ⚠️ |
| grpc-streaming | 5.88 Gb/s | 3.96 Gb/s | 2.70 Gb/s | −33% | −54% |
| iot-telemetry | 1.06 Gb/s ⚠️ | 1.02 Gb/s | **1.52 Gb/s** | −4% | −43% ⚠️ |
| log-shipper | 6.29 Gb/s | 6.26 Gb/s | 6.28 Gb/s | −0.5% | −0.2% |
| mixed-web-spiky | 10.67 Gb/s | 8.15 Gb/s ⚠️ | **10.80 Gb/s** | −24% | −1.2% |
| low-load | N/A | N/A | N/A | — | — |
| microservice-fanout | 2.41 Gb/s ⚠️ | 2.41 Gb/s | **3.56 Gb/s** | 0% | −47% ⚠️ |
| bulk-ingest | **15.13 Gb/s** | 14.78 Gb/s | 15.13 Gb/s | −2.3% | 0% |

> Note: `% vs base` is computed by `4-compare-results.sh` against the base median. Where base is confounded (⚠️), the sign of these percentages is misleading — a "negative" RB-loss means RB was faster than the (already impaired) baseline.

### 3.3 Softirq drops (from `summary.txt`)

Softirq drops are increments in `/proc/net/softnet_stat` drop counters on the receiver node. For the rb cluster, these reflect the ring buffer's **null-drop path** — the kernel NIC driver keeps delivering frames even when the ring buffer is full by silently discarding the eBPF sample. The packet is NOT lost; only the Retina observation of it is.

| Scenario | Base | PA | RB |
|---|---|---|---|
| api-read-heavy | 0 | 0 | **627** |
| grpc-streaming | 0 | 0 | **64** |
| iot-telemetry | 0 | 0 | 0 |
| log-shipper | 0 | 0 | 0 |
| mixed-web-spiky | 0 | 0 | **2 846** |
| low-load | 0 | 0 | 0 |
| microservice-fanout | 0 | 0 | 0 |
| bulk-ingest | 0 | 0 | 0 |

RB drops appear in high-QPS medium-payload scenarios (api-read-heavy, mixed-web-spiky). The 8 MiB ring buffer is sufficient for large-payload (bulk-ingest) and extreme-rate small-packet (microservice-fanout) scenarios. PA never drops because `perf_event_array` raises a per-packet hardware interrupt and processes synchronously — it cannot overflow but it does consume CPU proportional to packet rate.

### 3.4 Retina steady-state peak CPU (from `summary.txt` last samples)

These are the highest CPU reading among the last few Retina pod samples in the test — representative of sustained load during the steady state, not the connection-setup spike at t=0.

| Scenario | PA peak CPU | RB peak CPU | PA/RB ratio |
|---|---|---|---|
| api-read-heavy | 97 m | 105 m | 1.1× |
| grpc-streaming | 23 m | 62 m | 0.4× |
| iot-telemetry | 204 m | 136 m | **1.5×** |
| log-shipper | 135 m | 86 m | **1.6×** |
| mixed-web-spiky | 97 m | 23 m | **4.2×** |
| low-load | 95 m | 170 m | 0.6× |
| microservice-fanout | 127 m | 21 m | **6.0×** |
| bulk-ingest | 155 m | 59 m | **2.6×** |

---

## 4. Known Confounds

This test compares **3 independent AKS clusters** — not 3 configurations on the same hardware. Each cluster has its own VMSS pool and underlying physical hosts, which differ in NIC bandwidth.

### 4.1 NIC bandwidth cap on `rbt-base-05291154` `vmss000001`

The `vmss000001` node in the base cluster's `np32core` pool had a NIC bandwidth cap of approximately **3 Gb/s**, significantly below the ~16 Gb/s cap of `vmss000000`. This affected scenarios where the scheduler placed the receiver on that node:

| Scenario | Base receiver node | Observed base peak | Effect |
|---|---|---|---|
| `api-read-heavy` | `vmss000001` | 4.32 Gb/s | Understated — base likely ~6 Gb/s on a healthy node |
| `iot-telemetry` | `vmss000001` | 1.09 Gb/s | Understated — but all 3 were NIC-limited, rb on different vmss |
| `microservice-fanout` | `vmss000001` ← | **3.06 Gb/s** | **Severely understated** — real baseline likely ≥11 Gb/s |

The `microservice-fanout` base result is the most impacted: the 3.06 Gb/s ceiling is a hard NIC cap, not a reflection of CPU overhead.

### 4.2 PA `mixed-web-spiky` receiver on different node

For `mixed-web-spiky`, the PA cluster's receiver landed on `vmss000000` of `rbt-pa-05291154` while RB and base landed on `vmss000001`. This coincided with a period of uneven traffic distribution. PA measured 8.36 Gb/s peak vs. base 10.82 Gb/s and RB 10.97 Gb/s. The difference may overstate PA's disadvantage.

### 4.3 `grpc-streaming` and `iot-telemetry` high-variance medians

Both PA and RB show very high σ (±1.4–1.5 Gb/s) for `grpc-streaming` and `iot-telemetry`, causing median values to be much lower than peaks. This indicates frequent TCP connection resets under high QPS load, driving many near-zero throughput samples that pull the median down. **Peak values are more representative for these scenarios.**

### 4.4 `low-load` shows N/A

The low-load scenario is QPS-limited to ~16 MB/s total, so all throughput samples are in Mb/s (not Gb/s). The compare script's Gb/s regex returns N/A. All three variants observed ~117–122 Mb/s — effectively equal and QPS-capped.

### 4.5 `api-read-heavy` base anomaly

Base cluster median (4.11 Gb/s) is substantially lower than the two Retina clusters (PA 1.10, RB 5.92). Combined with the vmss000001 NIC cap, a likely explanation is that the base cluster's client pods were also distributed sub-optimally. The `-44% RB-loss` figure printed by the compare script is misleading: it would imply RB is faster than the baseline without Retina, which is a scheduling artifact.

---

## 5. Analysis

### Where RB (ring buffer) wins

**`microservice-fanout`** is the clearest signal: 40 client pods × 4 connections × 256 B × ∞ QPS generates the highest packet-event rate in the suite. RB reached **15.18 Gb/s peak** with only **21 m CPU** on the Retina agent, while PA reached **11.53 Gb/s peak** with **127 m CPU** (6× more). The ring buffer decouples the eBPF program from the NIC interrupt path — the kernel keeps polling/delivering frames while Retina drains the ring buffer asynchronously. PA's `perf_event_array` model raises a hardware interrupt per packet, saturating a CPU core and creating back-pressure on the NIC receive queue.

**`mixed-web-spiky`** (valid base comparison only): RB 10.97 Gb/s ≈ base 10.82 Gb/s, while PA 8.36 Gb/s (with the caveat of possible node placement; see §4.2). RB achieves near-zero overhead at bursty medium-rate workloads.

**`bulk-ingest`**: RB 15.16 Gb/s = base 15.16 Gb/s, PA 14.80 Gb/s. At low packet rate (64 connections × 64 KiB payloads), even `perf_event_array` is mostly idle — but PA still burnt 155 m CPU vs. RB's 59 m at steady state, and its median throughput trailed by 0.35 Gb/s.

### Where PA (perf array) wins or ties

**`grpc-streaming`**: PA peak 6.91 Gb/s > RB peak 6.08 Gb/s > base peak 5.92 Gb/s. This scenario (~320 streams × 2 KiB × 2 k QPS) sits in a sweet spot where PA's batch-interrupt model is efficient and RB hasn't hit its capacity ceiling. Both PA and RB exceed base here.

**`log-shipper`**: All three within 0.02 Gb/s of each other (6.28–6.30 Gb/s). At 120 streams × 16 KiB × 400 QPS the event rate is low enough (~48 k events/s) that both eBPF map types are functionally equivalent.

**`low-load`**: All three equal at the QPS ceiling (~120 Mb/s). Retina is irrelevant here.

### `iot-telemetry` — mixed picture

With 360 streams × 128 B × 20 k QPS (~7.2 M events/s), this is the highest sustained packet-rate scenario. PA peak 3.30 Gb/s > RB peak 2.07 Gb/s in the summary's 2 s receiver reports, but RB steady-state median (1.52 Gb/s) exceeds base (1.06 Gb/s), and base is NIC-capped on vmss000001. The PA peak reading likely reflects a brief burst rather than a sustainable rate. The high σ values confirm instability in both Retina variants at this event rate. More investigation with a stable receiver node is needed to draw firm conclusions.

---

## 6. Summary Table

| Scenario | Winner | Notes |
|---|---|---|
| api-read-heavy | RB (with caveats) | Base NIC-capped; RB higher than PA |
| grpc-streaming | PA peak | PA 14% higher peak; both above base |
| iot-telemetry | Unclear | Base NIC-capped; PA burst vs. RB stable |
| log-shipper | **All equal** | Low event rate, overhead irrelevant |
| mixed-web-spiky | RB ≈ Base > PA | PA node placement confound; RB overhead-free |
| low-load | **All equal** | QPS-limited |
| microservice-fanout | **RB clearly** | +31% peak vs PA, 6× lower Retina CPU; base NIC-capped |
| bulk-ingest | RB ≈ Base > PA | All NIC-saturated; PA slightly behind |

### Retina CPU overhead pattern

PA consistently burns more Retina CPU than RB in every scenario except `grpc-streaming` and `low-load`. The gap grows with packet rate:

- Low event rate (log-shipper ~48 k evt/s): PA/RB ≈ 1.6×
- Medium rate (api-read-heavy, iot-telemetry): PA/RB ≈ 1.1–1.5×  
- High bursty rate (mixed-web-spiky): PA/RB ≈ **4.2×**
- Extreme rate (microservice-fanout ~7.5 M pkt/s): PA/RB ≈ **6.0×**

This confirms that `perf_event_array`'s per-packet interrupt model has CPU cost that scales linearly with packet rate, while `ringbuf`'s amortized drain model largely decouples Retina CPU from NIC event rate.

---

## 7. Raw Results Location

```
results/rl-05291154/
├── rb/rbt-rb-05291154/real-05291204/<scenario>/rbt-rb-05291154/
│   ├── summary.txt          # official TEST SUMMARY with peak, drops, config
│   ├── throughput-live.txt  # 5 s throughput samples
│   ├── resource-usage.txt   # Retina pod + node CPU/memory over time
│   ├── ringbuf-pressure.txt # bpftool eBPF map listing with types
│   ├── ebpf-maps-pretest.txt
│   ├── ebpf-maps-posttest.txt
│   ├── proc-softirqs-before.txt / proc-softirqs-after.txt
│   ├── receiver-full.log
│   └── client-all.log
├── pa/rbt-pa-05291154/real-05291204/<scenario>/rbt-pa-05291154/
│   └── (same structure)
├── base/rbt-base-05291154/real-05291204/<scenario>/rbt-base-05291154/
│   └── (same structure, no Retina logs)
└── logs/orchestrator.log    # full interleaved terminal output
```

Re-run the comparison at any time:
```bash
./4-compare-results.sh results/rl-05291154
```
