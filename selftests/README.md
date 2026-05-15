# veth BQL Selftest

Stress test for veth's Byte Queue Limits (BQL) implementation.
Exercises BQL code paths under sustained UDP load, measures latency
reduction, and detects DQL accounting bugs (kernel BUG_ON/Oops).

Related upstream patchset:
[[PATCH net-next v5 0/5] veth: add Byte Queue Limits (BQL) support](https://lore.kernel.org/all/20260505132159.241305-1-hawk@kernel.org/)

## Files

| File                        | Description                                                    |
|-----------------------------|----------------------------------------------------------------|
| `veth_bql_test.sh`          | Inner test (runs inside VM or bare metal with root)            |
| `veth_bql_test_virtme.sh`   | Wrapper that boots a virtme-ng VM and runs the inner test      |
| `udp_flood.c`               | UDP flood generator with per-packet timestamps                 |
| `udp_sink.c`                | UDP sink with latency measurement and drop tracking            |
| `Makefile`                  | Builds `udp_flood` and `udp_sink`                              |
| `veth_bql_inflight.bt`      | bpftrace script for BQL inflight/limit histograms              |
| `napi_poll_hist.bt`         | bpftrace script for NAPI poll work histograms                  |
| `lib.sh`, `lib/sh/defer.sh` | Kernel kselftest library (from `tools/testing/selftests/net/`) |

## Build

```bash
cd selftests
make
```

The virtme wrapper (`veth_bql_test_virtme.sh`) runs `make` automatically.

## Prerequisites

- **gcc** for building the C tools
- **virtme-ng (vng)** installed (for VM-based testing)
- A compiled kernel tree with `vmlinux` and `.config` containing:
  `CONFIG_BQL=y`, `CONFIG_VETH=y`, `CONFIG_NET_SCH_SFQ=m`,
  `CONFIG_NET_SCH_FQ_CODEL=m`, and the virtio options for vng
- For `--hist`: `bpftrace` installed in the VM (usually available
  if the host kernel tree was built with BTF support)

## Quick Start

Run from a compiled kernel tree root:

```bash
cd /path/to/kernel-tree

# Quick validation with fq_codel
/path/to/selftests/veth_bql_test_virtme.sh --qdisc fq_codel

# With BQL inflight/limit histograms
/path/to/selftests/veth_bql_test_virtme.sh --qdisc sfq --hist

# A/B comparison: BQL disabled
/path/to/selftests/veth_bql_test_virtme.sh --qdisc fq_codel --bql-disable
```

## Options

All options except `--verbose` are forwarded to `veth_bql_test.sh`:

| Option              | Default | Description                                              |
|---------------------|---------|----------------------------------------------------------|
| `--verbose`         | off     | Show kernel console output (useful for BUG_ON debugging) |
| `--duration SEC`    | 30      | Test duration in seconds                                 |
| `--nrules N`        | 13000   | iptables rules to slow consumer NAPI (0=disable)         |
| `--qdisc NAME`      | sfq     | Qdisc to install on sender veth                          |
| `--qdisc-opts STR`  | (none)  | Extra qdisc parameters                                   |
| `--bql-disable`     | off     | Disable BQL (sets limit_min=1GB) for A/B comparison      |
| `--normal-napi`     | off     | Use softirq NAPI instead of threaded NAPI                |
| `--qdisc-replace`   | off     | Test live qdisc replacement under active traffic         |
| `--tiny-flood`      | off     | Add 2nd UDP thread with min-size packets                 |
| `--bql-min-limit N` | (none)  | Set DQL limit_min to N                                   |
| `--gro-disable`     | off     | Disable GRO on veth pair                                 |
| `--hist`            | off     | Print bpftrace histograms (BQL inflight, NAPI work)      |

## What It Measures

The test creates a veth pair, installs a qdisc, floods UDP packets,
slows the consumer with iptables rules, and reports:

- **Ping RTT under load** -- BQL should reduce from ~22ms to ~1.3ms
- **Packet loss** -- fq_codel should show 0% loss with BQL (vs 4% without)
- **BQL sysfs values** -- inflight, limit, hold_time
- **NAPI poll statistics** -- work per poll, cycle time
- **qdisc stats** -- packets, drops, requeues, backlog

## Example Runs

```bash
# Tiny-flood stress (tests BQL byte accounting with min-size packets)
.../veth_bql_test_virtme.sh --qdisc fq_codel --tiny-flood

# Live qdisc replacement stress test
.../veth_bql_test_virtme.sh --nrules 2000 --qdisc-replace --qdisc noqueue

# DQL tuning: limit_min=8 (one cache-line of ptr_ring pointers)
.../veth_bql_test_virtme.sh --qdisc sfq --tiny-flood --bql-min-limit 8

# Custom fq_codel tuning
.../veth_bql_test_virtme.sh --nrules 6000 --qdisc fq_codel --qdisc-opts 'target 2ms interval 20ms'
```

## Running Bare Metal (without virtme-ng)

The inner test can run directly on a machine with root:

```bash
sudo ./veth_bql_test.sh --duration 25 --qdisc sfq
```

This requires the running kernel to have BQL veth support and
pre-built binaries (`make` in this directory first).

## Results

Test output is saved to `results/selftests/<timestamp>/` with a
`results/selftests/latest` symlink pointing to the most recent run.
Each run directory contains: `veth_bql_test.log`, `veth_bql_console.log`,
`ping.log`, and bpftrace logs (`napi_poll.log`, `bql_inflight.log`).
