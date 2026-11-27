# Results

All 25 tests give the expected result.

- The code before the fix can reach the bad state. Every `+nobarrier`
  test gives `Sometimes`.
- The first version of the fix is not enough. The two
  `veth-busypoll-rearm` tests still give `Sometimes` with `+flush-only`.
- The final fix cannot reach the bad state in any test. Every `+wmb`,
  `+helper` and `+dmb-ishst` test gives `Never`.

[`README.md`](README.md) describes the race, the tests and the three
states of the code. Read "Limits of the tests" there before you rely on
these results.

## Test results

- `Sometimes`: herd7 found an execution that ends in the bad state.
- `Never`: no allowed execution ends in the bad state.
- `Bad` and `Other`: the number of executions that end in the bad
  state, and the number of other executions.
- `Run time`: wall-clock time. All tests ran in one batch, 12 at a time
  on 12 CPUs.

### LKMM tests

| Test                                      | Result    | Bad | Other | Run time |
|-------------------------------------------|-----------|-----|-------|----------|
| `veth-handoff+nobarrier`                  | Sometimes |   1 |     3 |     <1 s |
| `veth-handoff+wmb`                        | Never     |   0 |     3 |     <1 s |
| `veth-handoff-ctrl-dep+wmb`               | Never     |   0 |     3 |     <1 s |
| `veth-handoff-via-missed+nobarrier`       | Sometimes |   1 |     7 |     <1 s |
| `veth-handoff-via-missed+wmb`             | Never     |   0 |     5 |     <1 s |
| `veth-two-producers+nobarrier`            | Sometimes |   8 |    40 |    1 min |
| `veth-two-producers+wmb`                  | Never     |   0 |    28 |    1 min |
| `veth-two-cycles+nobarrier`               | Sometimes |  24 |    70 |   10 min |
| `veth-two-cycles+wmb`                     | Never     |   0 |    38 |   10 min |
| `veth-handoff-full+nobarrier`             | Sometimes |   1 |     6 |      4 s |
| `veth-handoff-full+flush-only`            | Never     |   0 |     4 |      4 s |
| `veth-handoff-full+helper`                | Never     |   0 |     4 |      4 s |
| `veth-busypoll-rearm+nobarrier`           | Sometimes |   1 |     4 |     14 s |
| `veth-busypoll-rearm+flush-only`          | Sometimes |   1 |     4 |     13 s |
| `veth-busypoll-rearm+helper`              | Never     |   0 |     4 |     13 s |
| `veth-busypoll-rearm-producer+nobarrier`  | Sometimes |  14 |    95 |   15 min |
| `veth-busypoll-rearm-producer+flush-only` | Sometimes |   7 |    84 |   15 min |
| `veth-busypoll-rearm-producer+helper`     | Never     |   0 |    74 |   15 min |

### arm64 tests

| Test                                | Result    | Bad | Other | Run time |
|-------------------------------------|-----------|-----|-------|----------|
| `veth-a64-lse+nobarrier`            | Sometimes |   4 |     8 |      1 s |
| `veth-a64-lse+dmb-ishst`            | Never     |   0 |     8 |      1 s |
| `veth-a64-lse-ctrl-dep+dmb-ishst`   | Never     |   0 |     8 |      1 s |
| `veth-a64-lse-via-missed+nobarrier` | Sometimes |   2 |    18 |      1 s |
| `veth-a64-lse-via-missed+dmb-ishst` | Never     |   0 |    13 |     <1 s |
| `veth-a64-llsc+nobarrier`           | Sometimes |   1 |     7 |      1 s |
| `veth-a64-llsc+dmb-ishst`           | Never     |   0 |     7 |      1 s |

herd7 prints `Flag Assuming-common-inner-shareable-domain` for every
arm64 test. The flag states a restriction of herd7's arm64 model: all
CPUs are in the same inner-shareable domain. The model then treats
`DMB ISH` and `DMB ISHST` like `DMB SY` and `DMB ST`.

The herd7 output of each test is in [`results/`](results/).

## What the results show

1. **The race is real in the model.** Without a barrier, the producer's
   `rx_notify_masked = true` store can land after the kthread's
   `rx_notify_masked = false` store. LKMM allows this, and herd7's arm64
   model allows it for the LSE and the LL/SC instructions.
2. **One `smp_wmb()` in the producer closes it.** The kthread needs no
   new barrier. Its control dependency on `test_bit()` is enough
   (`veth-handoff-ctrl-dep`, `veth-a64-lse-ctrl-dep`).
3. **The barrier must also be in the re-arm path.** With the barrier
   only in `__veth_xdp_flush()`, a re-arm from `busy_poll_stop()` can
   still latch `rx_notify_masked`. The helper `veth_napi_schedule()`
   closes this.
4. **The kthread's own re-arm needs no barrier.** `veth-handoff-full`
   gives `Never` with `+flush-only` and with `+helper`.
5. **A second producer does not break the fix.** It can set MISSED, or
   it can start a new NAPI cycle. The result stays `Never`.

## Extra checks

These checks are not part of `run-herd7.sh`. Each one lists the
commands that were used. In the commands, `$MM` is the path of this
`memory-model` directory.

### Which LKMM checks forbid the bad state

herd7 can skip a check of the model with `-skipcheck`. This shows which
rule forbids the bad state.

| Test                          | Checks skipped                    | Result    |
|-------------------------------|-----------------------------------|-----------|
| `veth-handoff+wmb`            | none                              | Never     |
| `veth-handoff+wmb`            | `happens-before`                  | Never     |
| `veth-handoff+wmb`            | `propagation`                     | Never     |
| `veth-handoff+wmb`            | `happens-before` and `propagation` | Sometimes |
| `veth-handoff-ctrl-dep+wmb`   | `happens-before`                  | Sometimes |
| `veth-handoff-ctrl-dep+wmb`   | `propagation`                     | Never     |
| `veth-handoff-via-missed+wmb` | `happens-before`                  | Sometimes |
| `veth-handoff-via-missed+wmb` | `propagation`                     | Never     |

Two separate orderings forbid the bad state in `veth-handoff+wmb`:

- The control dependency on `test_bit()` closes a `happens-before`
  cycle.
- The fully ordered `napi_complete_done()` closes a `propagation`
  cycle.

The other two tests have only the control dependency.

```bash
cd ~/git/linux/tools/memory-model
herd7 -conf linux-kernel.cfg -optace true -skipcheck happens-before \
	$MM/litmus/lkmm/veth-handoff+wmb.litmus
herd7 -conf linux-kernel.cfg -optace true -skipchecks happens-before,propagation \
	$MM/litmus/lkmm/veth-handoff+wmb.litmus
```

### The fix relies on the rmw-sequence rule of LKMM

A second producer can set MISSED on top of the first producer's
SCHED_THREADED. The kthread then reads SCHED_THREADED from the second
producer's update. The `smp_wmb()` of the first producer must still
apply. LKMM has a rule for this: `cumul-fence` extends through
`rmw-sequence`. Linux v6.3 added it, in commit ebd50e2947de ("tools:
memory-model: Add rmw-sequences to the LKMM").

This check removes the rule from a copy of the model:

```bash
cp -r ~/git/linux/tools/memory-model /tmp/lkmm-no-rmw-sequence
cd /tmp/lkmm-no-rmw-sequence
sed -i 's/^let rmw-sequence = (rf ; rmw)\*$/let rmw-sequence = id/' linux-kernel.cat
herd7 -conf linux-kernel.cfg -optace true $MM/litmus/lkmm/veth-two-producers+wmb.litmus
```

| Test                          | LKMM of v6.18 | Without `rmw-sequence` |
|-------------------------------|---------------|------------------------|
| `veth-handoff+wmb`            | Never         | Never                  |
| `veth-handoff-ctrl-dep+wmb`   | Never         | Never                  |
| `veth-handoff-via-missed+wmb` | Never         | Sometimes              |
| `veth-two-producers+wmb`      | Never         | Sometimes              |

So the fix relies on this rule when a second producer sets MISSED. Two
things support the rule for arm64:

- The commit message of ebd50e2947de says that the rule holds for arm64
  "because of other-multicopy atomicity".
- `veth-a64-lse-via-missed+dmb-ishst` gives `Never` in herd7's arm64
  model.

Use the LKMM of Linux v6.3 or later for these tests. An older LKMM
reports `Sometimes` for the two tests above.

### Cross-check without `-optace true`

`run-herd7.sh` gives `-optace true` to herd7 for the LKMM tests. A
second run used `./run-herd7.sh -q -x`, which leaves the option out.

The 20 quick tests gave the same herd7 output, byte for byte. The LKMM
tests took 4 to 10 times longer.

The 5 slow tests were not cross-checked. They are the two
`veth-two-cycles` tests and the three `veth-busypoll-rearm-producer`
tests.

## What the results do not show

- They do not show how often the race happens on real hardware. herd7
  checks which executions a model allows.
- They do not cover a real CPU. The arm64 tests use herd7's model of
  the architecture, and instructions written by hand from the kernel
  headers.
- They do not cover scenarios larger than the tests: more than three
  CPUs, or more than two polls by the kthread.

## Environment

| Item             | Value                                                        |
|------------------|--------------------------------------------------------------|
| Date             | 2026-11-27                                                   |
| herd7            | 7.58                                                         |
| LKMM             | `tools/memory-model` of Linux v6.18.65                       |
| arm64 model      | `aarch64.cat` of herd7 7.58 (the default for AArch64 tests)  |
| herd7 options    | `-conf linux-kernel.cfg -optace true` for the LKMM tests     |
| CPU              | 12th Gen Intel Core i7-12800H, 12 CPUs, 12 tests at a time   |

[`results/run-info.txt`](results/run-info.txt) has the checksums of the
LKMM files and the run time of each test in seconds.

## Reproduce

```bash
eval $(opam env)
cd memory-model
./run-herd7.sh -k ~/git/linux
git diff --stat results/
```

Only `results/run-info.txt` changes when the results are the same.
