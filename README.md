# veth Backpressure Performance Testing

Tools for testing and measuring veth qdisc backpressure and BQL (Byte
Queue Limits) behavior. This repository contains three independent test
suites:

## [`reproducer/`](reproducer/README.md) -- Backpressure Reproducer

Chris Arges' dark-buffer latency reproducer. Uses netns + `bbperf` to
demonstrate how veth's 256-entry `ptr_ring` acts as a "dark buffer"
hidden from the qdisc, causing head-of-line blocking and ping drops
under load.

See [`reproducer/README.md`](reproducer/README.md) for details.

## [`selftests/`](selftests/README.md) -- BQL Selftest

Stress test for the veth BQL patchset. Exercises BQL code paths under
sustained UDP load, measures latency reduction, and detects DQL
accounting bugs (kernel BUG_ON/Oops).

See [`selftests/README.md`](selftests/README.md) for details.

## [`memory-model/`](memory-model/README.md) -- Memory-Model Tests

herd7 litmus tests for the `rx_notify_masked` race in veth's NAPI
scheduling. They show that the old code can latch `rx_notify_masked`
with NAPI idle, and that the `smp_wmb()` fix prevents it. The tests use
the Linux-kernel memory model (LKMM) and herd7's arm64 model.

See [`memory-model/README.md`](memory-model/README.md) for details and
[`memory-model/RESULTS.md`](memory-model/RESULTS.md) for the results.

## Shared venv

The `reproducer/` suite uses `bbperf` (installed via `pip` into a
Python virtualenv). The venv lives at the repo root (`./venv/`) so it
can be shared between suites:

```bash
apt install python3-virtualenv
# venv is created automatically by reproducer/setup.sh on first run
```

## Related

- Upstream patchset: [[PATCH net-next v5 0/5] veth: add Byte Queue Limits (BQL) support](https://lore.kernel.org/all/20260505132159.241305-1-hawk@kernel.org/)

## License

GPL-2.0
