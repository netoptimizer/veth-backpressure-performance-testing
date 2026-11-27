# veth rx_notify_masked Memory-Model Tests

These are herd7 litmus tests for a memory-ordering race in the Linux
veth driver. The race leaves `rq->rx_notify_masked` at true while NAPI
is idle. After that, `__veth_xdp_flush()` never schedules NAPI again,
and traffic on that queue stalls.

The tests do two things:

- They show that the code before the fix can reach this bad state.
- They show that the code with the fix cannot reach it.

You do not need to run anything. [`RESULTS.md`](RESULTS.md) has the
result of every test.

Related kernel patch:
`veth: order rx_notify_masked store before __napi_schedule()`

## The race

`rx_notify_masked` tells a producer that NAPI is already scheduled.
This is the code before the fix (Linux v6.18, `drivers/net/veth.c`):

```c
static void __veth_xdp_flush(struct veth_rq *rq)
{
	/* Write ptr_ring before reading rx_notify_masked */
	smp_mb();
	if (!READ_ONCE(rq->rx_notify_masked) &&
	    napi_schedule_prep(&rq->xdp_napi)) {
		WRITE_ONCE(rq->rx_notify_masked, true);
		__napi_schedule(&rq->xdp_napi);
	}
}
```

With threaded NAPI, `__napi_schedule()` sets `NAPI_STATE_SCHED_THREADED`
with `set_bit()`. Then it wakes the NAPI kthread. `set_bit()` gives no
ordering. On a weakly ordered CPU such as arm64, other CPUs can see the
`SCHED_THREADED` store before the `rx_notify_masked` store.

The race needs a NAPI kthread that is awake. For example, the kthread
has just finished a poll and returns into `napi_thread_wait()`. It then
sees the bit with a plain `test_bit()`. A sleeping kthread is safe:
`wake_up_process()` runs a full barrier before it makes the kthread
runnable.

The kthread can then complete a full poll in between (`masked` is
`rq->rx_notify_masked`):

```
  producer CPU                    NAPI kthread
  ------------                    ------------
  WRITE_ONCE(masked, true)
  set_bit(SCHED_THREADED)
                                  test_bit(SCHED_THREADED)
                                  veth_poll()
                                    napi_complete_done()
                                    smp_store_mb(masked, false)
  store masked = true lands, overwrites false

  any producer CPU, later
  __veth_xdp_flush()
    masked is true: skip NAPI
```

The end state is `rx_notify_masked == true` with NAPI idle. No producer
schedules NAPI again.

The race exists since Linux v5.17, commit 68468d8c4cd4 ("veth: fix
races around rq->rx_notify_masked").

## The fix

```c
static void veth_napi_schedule(struct veth_rq *rq)
{
	if (napi_schedule_prep(&rq->xdp_napi)) {
		WRITE_ONCE(rq->rx_notify_masked, true);
		/* Order rx_notify_masked before NAPI_STATE_SCHED_THREADED */
		smp_wmb();
		__napi_schedule(&rq->xdp_napi);
	}
}
```

Both `__veth_xdp_flush()` and the re-arm path at the end of
`veth_poll()` call this helper.

The barrier is enough for these reasons:

1. Producer: `smp_wmb()` makes the `rx_notify_masked = true` store
   visible before the `SCHED_THREADED` store.
2. Kthread: it reads `SCHED_THREADED` first. Its
   `rx_notify_masked = false` store comes after that read. The control
   dependency on `test_bit()` orders the two. The fully ordered
   `cmpxchg()` in `napi_complete_done()` orders them a second time.
3. So the kthread's `false` store always lands after the producer's
   `true` store.

### Why the re-arm path needs the barrier too

This is the end of `veth_poll()` with the fix:

```c
	if (done < budget && napi_complete_done(napi, done)) {
		/* Write rx_notify_masked before reading ptr_ring */
		smp_store_mb(rq->rx_notify_masked, false);
		if (unlikely(!__ptr_ring_empty(&rq->xdp_ring)))
			veth_napi_schedule(rq);
	}
```

Normally the NAPI kthread runs `veth_poll()`. The re-arm and the next
poll are then on the same CPU, and no barrier is needed.

With socket busy polling (`SO_BUSY_POLL`, `net.core.busy_read`,
`net.core.busy_poll`), `busy_poll_stop()` calls `veth_poll()` on the
CPU of the application. The re-arm then hands NAPI to the kthread on
another CPU, in the same way as a producer.

### Three states of the code

The test names use these words:

| Name         | Where is `smp_wmb()`                          | Kernel code              |
|--------------|-----------------------------------------------|--------------------------|
| `nobarrier`  | nowhere                                       | before the fix (v6.18)   |
| `flush-only` | only in `__veth_xdp_flush()`                  | first version of the fix |
| `helper`     | in `veth_napi_schedule()`, used by both paths | final fix                |

Tests without a re-arm path use the name `wmb`. `flush-only` and
`helper` are the same code there.

## Files

| File                      | Description                                           |
|---------------------------|-------------------------------------------------------|
| `README.md`               | This file                                             |
| `RESULTS.md`              | Result of every test, and what the results mean       |
| `litmus/lkmm/*.litmus`    | Tests for the Linux-kernel memory model (C)           |
| `litmus/aarch64/*.litmus` | Tests for herd7's arm64 model (arm64 instructions)    |
| `gen-litmus.py`           | Generates all `.litmus` files                         |
| `run-herd7.sh`            | Runs the tests and checks the results                 |
| `results/*.out`           | herd7 output of the run that `RESULTS.md` describes   |
| `results/summary.tsv`     | One line for each test of that run                    |
| `results/run-info.txt`    | Tool versions and run times of that run               |

## The tests

Each test file starts with a comment. The comment describes the threads
and gives the expected result in a `Result:` line.

`Sometimes` means that herd7 found an execution that ends in the bad
state. `Never` means that no allowed execution ends in the bad state.

### LKMM tests

These tests use the Linux-kernel memory model (LKMM) from
`tools/memory-model` in the kernel tree. LKMM describes the ordering
that kernel code can rely on, on every architecture.

The file name is the test name plus the state of the code, for example
`veth-handoff+wmb.litmus`.

Tests without a re-arm path:

| Test                      | CPUs | What it models                                                          | `nobarrier` | `wmb` |
|---------------------------|------|-------------------------------------------------------------------------|-------------|-------|
| `veth-handoff`            | 2    | The race in its smallest form: one producer, one kthread                | Sometimes   | Never |
| `veth-handoff-ctrl-dep`   | 2    | Same, but only the control dependency orders the kthread's store        | -           | Never |
| `veth-handoff-via-missed` | 3    | The kthread sees SCHED_THREADED in a value that a second producer wrote | Sometimes   | Never |
| `veth-two-producers`      | 3    | The second producer sets MISSED, and the kthread polls again            | Sometimes   | Never |
| `veth-two-cycles`         | 3    | The second producer starts a new NAPI cycle (slow)                      | Sometimes   | Never |

Tests with a re-arm path:

| Test                           | CPUs | What it models                                         | `nobarrier` | `flush-only` | `helper` |
|--------------------------------|------|--------------------------------------------------------|-------------|--------------|----------|
| `veth-handoff-full`            | 2    | Adds the ring, MISSED and the kthread's own re-arm     | Sometimes   | Never        | Never    |
| `veth-busypoll-rearm`          | 2    | Re-arm from `busy_poll_stop()`, handed to the kthread  | Sometimes   | Sometimes    | Never    |
| `veth-busypoll-rearm-producer` | 3    | Same, with the producer of the ring entry (slow)       | Sometimes   | Sometimes    | Never    |

The two `veth-busypoll-rearm` tests are the reason for the helper. With
the barrier only in `__veth_xdp_flush()`, the bad state is still
reachable.

### arm64 tests

These tests use herd7's arm64 model. They contain the arm64
instructions that the kernel uses for each step.

| Test                      | What it models                                                  | `nobarrier` | `dmb-ishst` |
|---------------------------|-----------------------------------------------------------------|-------------|-------------|
| `veth-a64-lse`            | `veth-handoff` on CPUs with LSE atomics: `CASAL`, `STSET`       | Sometimes   | Never       |
| `veth-a64-lse-ctrl-dep`   | Same, but the kthread uses `CAS` in place of `CASAL`            | -           | Never       |
| `veth-a64-lse-via-missed` | `veth-handoff-via-missed` on CPUs with LSE atomics              | Sometimes   | Never       |
| `veth-a64-llsc`           | `veth-handoff` on CPUs without LSE: `LDXR`, `STXR`, `STLXR`     | Sometimes   | Never       |

`DMB ISHST` is the arm64 instruction for `smp_wmb()`.

## How the tests model the kernel

### The NAPI state word

`napi->state` is one word. Different CPUs change it with atomic
operations. The LKMM tests keep it as one `atomic_t` and encode it like
this:

```
state = count + 16 * T

count == 0    NAPI is idle (NAPI_STATE_SCHED is clear)
count == 1    NAPI_STATE_SCHED
count == 2    NAPI_STATE_SCHED | NAPI_STATE_MISSED
T             NAPI_STATE_SCHED_THREADED
```

So `state == 17` means SCHED and SCHED_THREADED. `state == 18` adds
MISSED. `state == 0` means idle.

| Kernel code                                      | Litmus code                                                      |
|--------------------------------------------------|------------------------------------------------------------------|
| `napi_schedule_prep()`                           | `o = atomic_fetch_add(1, state)`, true when `o == 0`             |
| `set_bit(NAPI_STATE_SCHED_THREADED)`             | `atomic_or(16, state)`                                           |
| `test_bit(NAPI_STATE_SCHED_THREADED)`            | `t = atomic_read(state)`, then `if (t & 16)`                     |
| `napi_complete_done()`                           | `o = atomic_fetch_sub(17, state)`, NAPI is idle when `o == 17`   |
| `WRITE_ONCE(rq->rx_notify_masked, true)`         | `WRITE_ONCE(*masked, 1)`                                         |
| `smp_store_mb(rq->rx_notify_masked, false)`      | `WRITE_ONCE(*masked, 0)`, then `smp_mb()`                        |
| `ptr_ring_produce()`                             | `WRITE_ONCE(*ring, 1)`                                           |
| `__ptr_ring_consume()` in `veth_xdp_rcv()`       | `c = READ_ONCE(*ring)`, then `WRITE_ONCE(*ring, 0)` when `c == 1` |
| `__ptr_ring_empty()`                             | `READ_ONCE(*ring)`                                               |

The reasons for these choices:

- `napi_schedule_prep()` is a `try_cmpxchg()` loop. It sets SCHED when
  SCHED is clear. It sets MISSED when SCHED is already set. The
  successful `cmpxchg()` is fully ordered. `atomic_fetch_add()` is also
  fully ordered, and it always succeeds.
- `set_bit()` is an atomic operation without a return value. It gives
  no ordering. `atomic_or()` is the same in LKMM.
- `napi_complete_done()` is also a `try_cmpxchg()` loop. It clears
  SCHED, MISSED and SCHED_THREADED. When MISSED was set, it keeps SCHED
  and schedules NAPI again. `atomic_fetch_sub(17, state)` does the same:
  17 becomes 0, and 18 becomes 1.

### The bad state

Every test ends with an `exists` clause. It describes the bad state:

```
exists (state=0 /\ masked=1)
```

NAPI is idle and `rx_notify_masked` is still true. Tests with a ring
also look for a lost wakeup, which is an idle NAPI with an entry left in
the ring:

```
exists (state=0 /\ (masked=1 \/ ring=1))
```

The two `via-missed` tests are cut down and do not complete NAPI. Their
clause is different. The comment in those files explains it.

### The awake kthread

The tests have no wakeup. The kthread starts with `test_bit()`, and
herd7 tries that read at every possible point. This models a kthread
that is awake.

### For memory-model people

The fix makes the race an instance of the "S" pattern. Compare
`tools/memory-model/litmus-tests/S+fencewmbonceonce+poacquireonce.litmus`.

```
producer:  W(masked,1) ->wmb-> W(state)
kthread:   R(state) ->ctrl,mb-> W(masked,0)
```

The kthread reads `state` from the producer's write, or from a later
atomic update of that word. The bad state needs
`W(masked,0) ->co-> W(masked,1)`. With the `smp_wmb()`, that closes two
cycles, and LKMM forbids each of them:

- a cycle in `hb`, through the control dependency
- a cycle in `pb`, through the fully ordered `napi_complete_done()`

herd7 confirms this for `veth-handoff+wmb`. The result stays `Never`
with `-skipcheck happens-before`, and also with
`-skipcheck propagation`. It changes to `Sometimes` only when both
checks are skipped. `veth-handoff-ctrl-dep+wmb` has only the control
dependency, so there the `hb` check alone forbids the bad state.

A second producer can set MISSED on top of the first producer's
SCHED_THREADED. The kthread then reads `state` from the second
producer's update, not from the first producer's `set_bit()`. The fence
must still apply. In LKMM it does: `cumul-fence` extends through
`rmw-sequence`. This rule is in LKMM since Linux v6.3, commit
ebd50e2947de ("tools: memory-model: Add rmw-sequences to the LKMM").

`veth-handoff-via-missed` is the smallest test for this case, and
`veth-two-producers` contains it. Both `+wmb` tests change to
`Sometimes` when the rule is removed from the model. `RESULTS.md` has
the details. `veth-a64-lse-via-missed` shows that herd7's arm64 model
forbids the bad state too.

## Limits of the tests

- The scenarios are small. They have at most three CPUs, at most two
  polls by the kthread, and one ring slot.
- The NAPI kthread is always awake.
- The tests cover threaded NAPI only. Without threaded NAPI,
  `__napi_schedule()` queues the poll on the CPU of the caller.
- Only SCHED, MISSED and SCHED_THREADED of `napi->state` are modelled.
  `napi_disable()`, netpoll and a change of the threaded mode are not.
- `napi_complete_done()` can clear SCHED and still return false. That
  happens with `gro_flush_timeout` and `napi_defer_hard_irqs`. The
  tests do not model this path.
- The arm64 tests are written by hand from the kernel's arm64 headers.
  They are not taken from a compiled kernel. They do not model the
  retry after a failed store-exclusive.
- herd7 checks which executions the memory model allows. It cannot say
  how often the race happens on real hardware.
- `run-herd7.sh` gives `-optace true` to herd7 for the LKMM tests.
  herd7 then drops impossible candidates earlier. `RESULTS.md`
  describes a cross-check without this option.

## Run the tests

You need:

- `herd7` version 7.58 or later. `opam install herdtools7` installs it.
  See <https://github.com/herd/herdtools7>.
- A Linux kernel source tree, v6.3 or later. The LKMM tests use the
  model files in its `tools/memory-model` directory. The recorded
  results used v6.18.
- Python 3, but only to generate the litmus files again.

```bash
eval $(opam env)                        # puts herd7 in PATH
cd memory-model
./run-herd7.sh -k ~/git/linux -q        # quick: skips the slow tests
./run-herd7.sh -k ~/git/linux           # all tests
```

The quick run takes about one minute. The full run takes about 15
minutes when it can use five CPUs or more. `./run-herd7.sh -h` lists
all options.

The script compares each result with the `Result:` line of the test.
It prints `PASS` or `FAIL` for each test. Its exit status is 0 when all
tests pass.

A full run writes into `results/`. Use `git diff results/` afterwards.
Only `results/run-info.txt` changes when your results are the same as
the recorded ones.

A quick run, or a run of selected tests, writes into
`results-partial/`. Git ignores that directory.

To run one test by hand:

```bash
MM=$PWD                                  # this memory-model directory

# LKMM test: herd7 must run in the kernel's tools/memory-model directory
cd ~/git/linux/tools/memory-model
herd7 -conf linux-kernel.cfg -optace true $MM/litmus/lkmm/veth-handoff+wmb.litmus

# arm64 test: no kernel tree needed
cd $MM
herd7 litmus/aarch64/veth-a64-lse+nobarrier.litmus
```

## Read the herd7 output

This is the output for `veth-handoff+nobarrier`:

```
Test veth-handoff+nobarrier Allowed
States 3
[masked]=0; [state]=0;
[masked]=1; [state]=0;
[masked]=1; [state]=17;
Ok
Witnesses
Positive: 1 Negative: 3
Condition exists ([state]=0 /\ [masked]=1)
Observation veth-handoff+nobarrier Sometimes 1 3
```

- `States` lists every final state that herd7 found. The second line,
  `[masked]=1; [state]=0;`, is the bad state.
- `Positive` counts the executions that end in the bad state.
  `Negative` counts the other executions.
- `Observation ... Sometimes` means that the bad state is reachable.

With the fix, the bad state is gone:

```
Test veth-handoff+wmb Allowed
States 2
[masked]=0; [state]=0;
[masked]=1; [state]=17;
No
Witnesses
Positive: 0 Negative: 3
Condition exists ([state]=0 /\ [masked]=1)
Observation veth-handoff+wmb Never 0 3
```

The state `[masked]=1; [state]=17;` is not a problem. NAPI is scheduled
there, and the kthread did not poll yet.

## Change the tests

`gen-litmus.py` generates every `.litmus` file. Do not edit the
`.litmus` files by hand.

```bash
./gen-litmus.py            # writes litmus/lkmm and litmus/aarch64
./gen-litmus.py --check    # verifies that the files match the script
```

herd7 tries every possible execution. The run time grows fast with the
number of reads and writes of one variable. Keep new tests small.
