# Retina Ring Buffer vs Perf Event Array — Performance Test

Performance test framework for [microsoft/retina PR #1981](https://github.com/microsoft/retina/pull/1981) comparing ring buffer and perf event array implementations for the packet parser eBPF program on multi-core nodes.

## Test Design

Replicates the traffic pattern from Zain's blog post: `SO_REUSEPORT` distributes TCP connections across all CPU cores, exercising per-CPU contention in the eBPF data path.

- **Receiver:** Single pod with 32 `SO_REUSEPORT` listeners (one per core), each with a 32-worker pool
- **Clients:** 20 pods × 16 TCP connections = 320 concurrent streams flooding 4KB payloads
- **Node:** Standard_D32s_v3 (32 vCPU) on AKS with azure overlay CNI
- **Duration:** 120s per test, throughput sampled every 2s at receiver

## Results (2026-05-21)

| Metric | Baseline (no Retina) | Perf Array | Ring Buffer |
|--------|---------------------|------------|-------------|
| Steady-state throughput | 15.20 Gb/s | ~7.0 Gb/s | ~7.5 Gb/s |
| Stability | ±0.02 Gb/s | Highly variable (6.7–15.2) | Stable (±0.5) |
| Peak | 16.22 Gb/s | 15.32 Gb/s | 15.21 Gb/s |
| Throughput loss | — | ~54% | ~50% |
| Softirq drops | 0 | 0 | 0 |

**Key finding:** Ring buffer eliminates the throughput variance/instability of perf array and provides slightly better median throughput (~7% improvement), but both show ~50% loss on 32-core under heavy load.

### eBPF Maps (Ring Buffer cluster)

| Map ID | Name | Type | Size | Memlock |
|--------|------|------|------|---------|
| 63 | `retina_filter` | lpm_trie | 255 entries | 4KB |
| 64 | `retina_conntrac` | lru_hash | 262,144 entries | 37.7MB |
| 73 | `events` | ringbuf | 4MB | 0 |
| 74 | `sk_cache` | percpu_hash | 8,192 entries | 6.4MB |
| 84,108,153,189,203,224,245 | `retina_packetpa` | ringbuf | 8MB each | 0 |

7 ring buffer maps (`retina_packetpa`) × 8MB = **56MB total** for the packet parser ring buffers (one per retina-agent pod).

## Directory Structure

```
├── cmd/
│   ├── client/main.go      # TCP flood client (configurable conns, duration, payload)
│   └── receiver/main.go    # SO_REUSEPORT TCP receiver with throughput reporting
├── deploy/
│   ├── client.yaml         # 20-replica client deployment
│   ├── receiver.yaml       # Receiver on 32-core node
│   └── monitor.yaml        # Privileged pod for bpftool/softirq capture
├── results/                # Full test output per variant
│   ├── rbt-base-05211604/  # Baseline (no Retina)
│   ├── rbt-pa-05211604/    # Perf array (packetParserRingBuffer=disabled)
│   └── rbt-rb-05211604/    # Ring buffer (packetParserRingBuffer=enabled)
├── logs/                   # Full terminal logs from test runs
├── 0-build-images.sh       # Compile Go binaries + build container images
├── 1-create-clusters.sh    # Create AKS cluster + 32-core nodepool
├── 2-setup-retina.sh       # Install Retina with specified buffer mode
├── 3-run-test.sh           # Run test with full logging (eBPF maps, softirq, throughput)
├── 4-compare-results.sh    # Generate comparison table
├── 5-destroy.sh            # Delete cluster resources
├── 6-run-matrix.sh         # Sweep load/QPS/payload combinations
├── 7-real-life-scenarios.sh # Run realistic workload presets
├── run-sequential.sh       # Orchestrate all 3 variants sequentially
└── push-to-acr.sh          # Push images to ACR (handles DNS issues)
```

## Usage

### Quick run (all 3 variants sequentially)
```bash
./run-sequential.sh
```

### Individual steps
```bash
# 1. Build and push images
./0-build-images.sh
./push-to-acr.sh

# 2. Create cluster
./1-create-clusters.sh <cluster-name> <resource-group> <location>

# 3. Install Retina (mode: none/enabled/disabled)
./2-setup-retina.sh <cluster-name> <resource-group> <mode>

# 4. Run test
./3-run-test.sh <cluster-name> <resource-group> <duration> <results-dir>

# 4b. Run a custom load profile
./3-run-test.sh <cluster-name> <resource-group> <duration> <results-dir> <client-replicas> <conns-per-pod> <payload-bytes> <qps-per-conn>

# 4c. Sweep load/QPS/payload matrix on one cluster
./6-run-matrix.sh <cluster-name> <resource-group> <duration> <results-dir>

# 4d. Run realistic preset scenarios (default 900s duration)
./7-real-life-scenarios.sh <cluster-name> <resource-group> <scenario|all> [duration] [results-dir]

# 5. Cleanup
./5-destroy.sh <resource-group>
```

### Load and Kernel Validation

`3-run-test.sh` now supports explicit traffic-shaping knobs:

- client replicas (pod count)
- connections per pod
- payload size in bytes
- writes/sec per connection (`qps`, with `0` as unlimited)

QPS supports parsed suffixes for larger long-run rates:

- `5000` = 5,000 writes/sec per connection
- `5k` = 5,000 writes/sec per connection
- `2m` = 2,000,000 writes/sec per connection
- `1g` = 1,000,000,000 writes/sec per connection

Each test run also captures host kernel/network environment in `kernel-env.txt`, including:

- `net.core` socket buffer limits (`rmem_*`, `wmem_*`)
- queue/backlog settings (`netdev_max_backlog`, `somaxconn`, `tcp_max_syn_backlog`)
- TCP buffer autotuning (`tcp_rmem`, `tcp_wmem`, `tcp_moderate_rcvbuf`)
- NIC queue RPS settings (`rps_cpus`, `rps_flow_cnt`)

### Real-World Scenario Presets

`7-real-life-scenarios.sh` includes practical workload profiles:

- `api-read-heavy` — many small calls (`payload=512`, high QPS)
- `grpc-streaming` — medium payload sustained streams
- `iot-telemetry` — tiny payload + very high QPS
- `log-shipper` — larger payload at moderate QPS
- `mixed-web-spiky` — mixed web-style traffic profile

Run all presets in one pass:

```bash
./7-real-life-scenarios.sh <cluster> <rg> all 900
```

## Collected Data Per Test

Each test captures:
- `summary.txt` — Throughput readings, peak, softirq drops, eBPF map sizes, Retina config
- `throughput-live.txt` — Live throughput samples during test
- `receiver-full.log` — Complete receiver pod logs
- `client-all.log` — All client pod logs
- `ebpf-maps-{pre,post}test.txt` — eBPF map types/sizes/memlock via bpftool
- `retina-{pretest,posttest}.log` — Retina agent logs
- `proc-softirqs-{before,after}.txt` — /proc/softirqs snapshots
- `net-rx-delta.txt` — NET_RX softirq delta per CPU

## Prerequisites

- Azure subscription with DSv3 quota (64 vCPUs for 2× Standard_D32s_v3)
- `az` CLI with aks-preview extension
- `kubectl`, `helm`
- Go 1.25+ (for building binaries)
- `buildah` or Docker (for container images)
- ACR with push access
