# Initial Ring Buffer vs Perf Array Benchmark — 2026-05-21

**Run ID:** `rbt-05211604`  
**Date:** May 21, 2026  
**Duration:** 120 s  
**Node SKU:** Standard_D32s_v3 (32 vCPU, single NUMA), canadacentral  
**K8s:** AKS, azure overlay CNI  

---

## Test Design

Replicates the traffic pattern from Zain's blog post (`SO_REUSEPORT` distributes TCP connections across all CPU cores):

- **Receiver:** Single pod with 32 `SO_REUSEPORT` listeners (one per core), each with a 32-worker pool
- **Clients:** 20 pods × 16 TCP connections = **320 concurrent streams**, 4 KB payloads, unlimited QPS
- **Duration:** 120 s, throughput sampled every 2 s at receiver

---

## Results

| Metric | Baseline (no Retina) | Perf Array | Ring Buffer |
|---|---|---|---|
| Steady-state throughput | 15.20 Gb/s | ~7.0 Gb/s | ~7.5 Gb/s |
| Stability | ±0.02 Gb/s | Highly variable (6.7–15.2) | Stable (±0.5) |
| Peak | 16.22 Gb/s | 15.32 Gb/s | 15.21 Gb/s |
| Throughput loss vs base | — | ~54% | ~50% |
| Softirq drops | 0 | 0 | 0 |

**Key finding:** Ring buffer eliminates the throughput variance and instability of perf array and provides slightly better median throughput (~7% improvement), but both show ~50% steady-state loss on a 32-core single-NUMA node under this load profile.

> **Note on single-NUMA:** Both variants show roughly equal penalty here because D32s_v3 has a single NUMA node — the cross-NUMA buffer polling overhead that dominates on multi-NUMA Falcon nodes (160 CPU, 5 NUMA) is absent. See `results/rl-05291154/RESULTS.md` for the multi-scenario results, and `results/falcon-numa-*/` for the NUMA reproduction test.

---

## eBPF Maps (Ring Buffer cluster)

| Map ID | Name | Type | Size | Memlock |
|---|---|---|---|---|
| 63 | `retina_filter` | lpm_trie | 255 entries | 4 KB |
| 64 | `retina_conntrac` | lru_hash | 262,144 entries | 37.7 MB |
| 73 | `events` | ringbuf | 4 MB | 0 |
| 74 | `sk_cache` | percpu_hash | 8,192 entries | 6.4 MB |
| 84,108,153,189,203,224,245 | `retina_packetpa` | ringbuf | 8 MB each | 0 |

7 ring buffer maps × 8 MB = **56 MB total** for packet parser ring buffers (one per retina-agent pod).

---

## Raw Data

```
results/rbt-base-05211604/   — Baseline (no Retina)
results/rbt-pa-05211604/     — Perf array  (packetParserRingBuffer=disabled)
results/rbt-rb-05211604/     — Ring buffer (packetParserRingBuffer=enabled)
```

Each directory contains: `summary.txt`, `throughput-live.txt`, `ebpf-maps-{pre,post}test.txt`, `proc-softirqs-{before,after}.txt`, `receiver-full.log`, `client-all.log`, `cluster-info.txt`.
