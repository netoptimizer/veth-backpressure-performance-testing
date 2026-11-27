#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Generate the herd7 litmus tests for the veth rx_notify_masked race.

The tests are small models of drivers/net/veth.c and of the NAPI core in
net/core/dev.c.  README.md explains the model and each test.

Usage:
    gen-litmus.py            write litmus/lkmm/*.litmus and litmus/aarch64/*.litmus
    gen-litmus.py --check    verify that the committed files match this script

LKMM tests (C)
--------------
napi->state is one word.  The tests encode it as

    state = count + 16 * T

    count == 0    NAPI is idle (NAPI_STATE_SCHED is clear)
    count == 1    NAPI_STATE_SCHED
    count == 2    NAPI_STATE_SCHED | NAPI_STATE_MISSED
    T             NAPI_STATE_SCHED_THREADED

    napi_schedule_prep()     old = atomic_fetch_add(1, state)
                             returns true when old == 0
    set_bit(SCHED_THREADED)  atomic_or(16, state)
    test_bit(SCHED_THREADED) atomic_read(state) & 16
    napi_complete_done()     old = atomic_fetch_sub(17, state)
                             NAPI is idle when old == 17 (no MISSED)

arm64 tests (assembly)
----------------------
These use the real bit values: SCHED = 0x1, SCHED_THREADED = 0x200.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

T_BIT = 16                  # SCHED_THREADED in the LKMM encoding
OWNED_KTHREAD = T_BIT + 1   # SCHED | SCHED_THREADED
OWNED_SCHED = 1             # SCHED only

# Where the smp_wmb() is, for the three states of the kernel code:
#   name          (__veth_xdp_flush() path, veth_poll() re-arm path)
MODES = {
    "nobarrier":  (False, False),
    "wmb":        (True,  True),
    "flush-only": (True,  False),
    "helper":     (True,  True),
}

MODE_DOC = {
    "nobarrier":
        "smp_wmb(): none.  This is the code before the fix.",
    "wmb":
        "smp_wmb(): before __napi_schedule().  This is the fix.",
    "flush-only":
        "smp_wmb(): in __veth_xdp_flush() only.  This is the first version of\n"
        "the fix.  The re-arm path in veth_poll() has no barrier.",
    "helper":
        "smp_wmb(): in veth_napi_schedule().  __veth_xdp_flush() and the\n"
        "re-arm path in veth_poll() both call it.  This is the final fix.",
}

ENCODING_DOC = """\
napi->state is one word: state = count + 16 * T
  count: 0 = idle, 1 = SCHED, 2 = SCHED | MISSED
  T:     SCHED_THREADED"""

BAD_STUCK = """\
Bad state: NAPI is idle (state == 0) and rx_notify_masked is still
true.  __veth_xdp_flush() then never schedules NAPI again."""

BAD_STUCK_OR_LOST = """\
Bad state: NAPI is idle (state == 0) and rx_notify_masked is still
true, or NAPI is idle and the ring still holds an entry."""

EXISTS_STUCK = "state=0 /\\ masked=1"
EXISTS_STUCK_OR_LOST = "state=0 /\\ (masked=1 \\/ ring=1)"


class Thread:
    """Collects the C statements of one litmus thread."""

    def __init__(self):
        self.regs = []
        self.lines = []
        self.depth = 1
        self.nreg = {}

    def reg(self, base):
        n = self.nreg.get(base, 0) + 1
        self.nreg[base] = n
        name = "%s%d" % (base, n)
        self.regs.append(name)
        return name

    def emit(self, code, comment=None):
        line = "\t" * self.depth + code
        if comment:
            line += " /* %s */" % comment
        self.lines.append(line)

    def note(self, comment):
        self.lines.append("\t" * self.depth + "/* %s */" % comment)

    def open(self, cond):
        self.emit("if (%s) {" % cond)
        self.depth += 1

    def orelse(self):
        self.depth -= 1
        self.emit("} else {")
        self.depth += 1

    def close(self):
        self.depth -= 1
        self.emit("}")


def veth_napi_schedule(t, wmb):
    """napi_schedule_prep(); rx_notify_masked = true; __napi_schedule()"""
    o = t.reg("o")
    t.emit("%s = atomic_fetch_add(1, state);" % o, "napi_schedule_prep()")
    t.open("%s == 0" % o)
    t.emit("WRITE_ONCE(*masked, 1);")
    if wmb:
        t.emit("smp_wmb();", "the fix")
    t.emit("atomic_or(%d, state);" % T_BIT, "set_bit(SCHED_THREADED)")
    t.close()


def veth_xdp_flush(t, wmb, ring=False):
    """[ptr_ring_produce();] __veth_xdp_flush()"""
    if ring:
        t.emit("WRITE_ONCE(*ring, 1);", "ptr_ring_produce()")
    t.emit("smp_mb();", "__veth_xdp_flush()")
    m = t.reg("m")
    t.emit("%s = READ_ONCE(*masked);" % m)
    t.open("%s == 0" % m)
    veth_napi_schedule(t, wmb)
    t.close()


def veth_poll_idle(t, ring=False, rearm_wmb=False):
    """veth_poll() after napi_complete_done() returned true"""
    t.emit("WRITE_ONCE(*masked, 0);", "smp_store_mb()")
    t.emit("smp_mb();")
    if ring:
        e = t.reg("e")
        t.emit("%s = READ_ONCE(*ring);" % e, "!__ptr_ring_empty()")
        t.open("%s == 1" % e)
        veth_napi_schedule(t, rearm_wmb)
        t.close()


def veth_poll_tail(t, owned, ring=False, rearm_wmb=False, relaxed=False,
                   missed="resched", then=None):
    """
    End of veth_poll(): napi_complete_done(), then veth_poll_idle().

    owned    what the caller holds in napi->state: OWNED_KTHREAD or
             OWNED_SCHED.
    missed   what to model when napi_complete_done() finds MISSED:
             "resched"  __napi_schedule() sets SCHED_THREADED; test ends
             "repoll"   the kthread polls once more
             "stop"     nothing; NAPI stays scheduled and the test ends
    then     callback, emitted at the end of the "NAPI is idle" branch
    """
    o = t.reg("o")
    op = "atomic_fetch_sub_relaxed" if relaxed else "atomic_fetch_sub"
    t.emit("%s = %s(%d, state);" % (o, op, owned), "napi_complete_done()")
    t.open("%s == %d" % (o, owned))
    veth_poll_idle(t, ring, rearm_wmb)
    if then:
        then()
    if missed == "resched":
        t.orelse()
        t.emit("atomic_or(%d, state);" % T_BIT, "MISSED: __napi_schedule()")
    elif missed == "repoll":
        t.orelse()
        t.note("MISSED: SCHED stays set, the kthread polls again")
        veth_poll_tail(t, OWNED_SCHED, missed="stop")
    t.close()


def napi_kthread(t, ring=False, rearm_wmb=False, relaxed=False,
                 missed="resched", cycles=1):
    """napi_threaded_poll(): napi_thread_wait(), then veth_poll()"""
    r = t.reg("t")
    t.emit("%s = atomic_read(state);" % r, "test_bit(SCHED_THREADED)")
    t.open("%s & %d" % (r, T_BIT))
    if ring:
        c = t.reg("c")
        t.emit("%s = READ_ONCE(*ring);" % c, "veth_xdp_rcv()")
        t.open("%s == 1" % c)
        t.emit("WRITE_ONCE(*ring, 0);")
        t.close()
    then = None
    if cycles > 1:
        def then():
            napi_kthread(t, ring, rearm_wmb, relaxed, missed, cycles - 1)
    veth_poll_tail(t, OWNED_KTHREAD, ring, rearm_wmb, relaxed, missed, then)
    t.close()


def lkmm_render(name, result, doc, init, threads, exists, slow=None):
    args = ["atomic_t *state", "int *masked"]
    if any("ring" in line for th in threads for line in th.lines):
        args.append("int *ring")
    out = ["C %s" % name, "", "(*", " * Result: %s" % result]
    if slow:
        out.append(" * Runtime: slow (%s)" % slow)
    out.append(" *")
    for line in doc.strip("\n").split("\n"):
        out.append((" * " + line).rstrip())
    out += [" *)", "", "{"]
    out += ["\t" + i for i in init]
    out += ["}", ""]
    for i, th in enumerate(threads):
        out.append("P%d(%s)" % (i, ", ".join(args)))
        out.append("{")
        if th.regs:
            out += ["\tint %s;" % r for r in th.regs]
            out.append("")
        out += th.lines
        out += ["}", ""]
    out.append("exists (%s)" % exists)
    return "\n".join(out) + "\n"


def lkmm_tests():
    out = []
    init = ["atomic_t state = ATOMIC_INIT(0);", "int masked = 0;"]

    def add(name, result, doc, bad, exists, init, threads, slow=None):
        doc = doc.strip("\n") + "\n\n" + bad + "\n\n" + ENCODING_DOC
        out.append((name, lkmm_render(name, result, doc, init, threads,
                                      exists, slow)))

    # --- producer -> NAPI kthread, smallest form -------------------------
    for mode, result in (("nobarrier", "Sometimes"), ("wmb", "Never")):
        flush_wmb, rearm_wmb = MODES[mode]
        p = Thread()
        veth_xdp_flush(p, flush_wmb)
        k = Thread()
        napi_kthread(k, missed="stop")
        add("veth-handoff+" + mode, result, """
The race in its smallest form.

P0: producer in __veth_xdp_flush().  It takes SCHED, sets
    rx_notify_masked, then sets SCHED_THREADED.
P1: NAPI kthread that is awake.  It sees SCHED_THREADED in
    napi_thread_wait(), polls, completes NAPI, then clears
    rx_notify_masked.

""" + MODE_DOC[mode], BAD_STUCK, EXISTS_STUCK, init, [p, k])

    # --- same; only the control dependency orders the kthread's store ----
    p = Thread()
    veth_xdp_flush(p, True)
    k = Thread()
    napi_kthread(k, relaxed=True, missed="stop")
    add("veth-handoff-ctrl-dep+wmb", "Never", """
Same as veth-handoff+wmb, but napi_complete_done() is a relaxed
(unordered) RMW here.  The kernel uses a fully ordered cmpxchg().

This shows that the control dependency from test_bit() alone already
orders the kthread's rx_notify_masked = false store after the read.

""" + MODE_DOC["wmb"], BAD_STUCK, EXISTS_STUCK, init, [p, k])

    # --- kthread sees SCHED_THREADED through another CPU's update --------
    for mode, result in (("nobarrier", "Sometimes"), ("wmb", "Never")):
        flush_wmb, rearm_wmb = MODES[mode]
        a = Thread()
        a.emit("WRITE_ONCE(*masked, 1);")
        if flush_wmb:
            a.emit("smp_wmb();", "the fix")
        a.emit("atomic_or(%d, state);" % T_BIT, "set_bit(SCHED_THREADED)")
        b = Thread()
        o = b.reg("o")
        b.emit("%s = atomic_cmpxchg(state, %d, %d);" %
               (o, OWNED_KTHREAD, OWNED_KTHREAD + 1),
               "napi_schedule_prep() sets MISSED")
        k = Thread()
        t = k.reg("t")
        k.emit("%s = atomic_read(state);" % t, "test_bit(SCHED_THREADED)")
        k.open("%s & %d" % (t, T_BIT))
        k.emit("WRITE_ONCE(*masked, 0);", "smp_store_mb()")
        k.emit("smp_mb();")
        k.close()
        add("veth-handoff-via-missed+" + mode, result, """
The kthread sees SCHED_THREADED in a value that another CPU wrote.

This test is cut down to one ordering question.  It starts after the
first producer took SCHED (state starts at 1).

P0: first producer.  It sets rx_notify_masked, then SCHED_THREADED.
P1: second producer.  Its napi_schedule_prep() finds SCHED set and
    sets MISSED.  The cmpxchg() succeeds only on top of P0's
    SCHED_THREADED (17 -> 18).
P2: NAPI kthread.  test_bit(SCHED_THREADED), then rx_notify_masked =
    false.  NAPI completion is left out.

With the smp_wmb(), LKMM forbids the bad state through its
rmw-sequence rule (Linux v6.3, commit ebd50e2947de).  The arm64 test
veth-a64-lse-via-missed checks the same case on arm64.

""" + MODE_DOC[mode], """\
Bad state: the kthread read state == 18, so it saw SCHED_THREADED
through P1's update.  It cleared rx_notify_masked.  But
rx_notify_masked is true at the end: P0's store landed last.""",
            "2:t1=%d /\\ masked=1" % (OWNED_KTHREAD + 1),
            ["atomic_t state = ATOMIC_INIT(1);", "int masked = 0;"],
            [a, b, k])

    # --- producer -> NAPI kthread, with ring, MISSED and re-arm ----------
    for mode, result in (("nobarrier", "Sometimes"),
                         ("flush-only", "Never"), ("helper", "Never")):
        flush_wmb, rearm_wmb = MODES[mode]
        p = Thread()
        veth_xdp_flush(p, flush_wmb, ring=True)
        k = Thread()
        napi_kthread(k, ring=True, rearm_wmb=rearm_wmb)
        add("veth-handoff-full+" + mode, result, """
As veth-handoff, with more of the driver logic.

P0: producer: ptr_ring_produce(), then __veth_xdp_flush().
P1: NAPI kthread, one poll.  It consumes the ring entry, completes
    NAPI, clears rx_notify_masked, checks the ring again and re-arms
    NAPI when the ring is not empty.  When napi_complete_done() finds
    MISSED, it schedules NAPI again and the test ends.

The re-arm here runs on the kthread itself, so it needs no barrier:
flush-only and helper give the same result.

""" + MODE_DOC[mode], BAD_STUCK_OR_LOST, EXISTS_STUCK_OR_LOST,
            init + ["int ring = 0;"], [p, k])

    # --- two producers; the second one can set MISSED --------------------
    for mode, result in (("nobarrier", "Sometimes"), ("wmb", "Never")):
        flush_wmb, rearm_wmb = MODES[mode]
        a = Thread()
        veth_xdp_flush(a, flush_wmb)
        b = Thread()
        veth_xdp_flush(b, flush_wmb)
        k = Thread()
        napi_kthread(k, missed="repoll")
        add("veth-two-producers+" + mode, result, """
Two producers and the NAPI kthread.

P0, P1: producers in __veth_xdp_flush().  One takes SCHED.  The other
    sees rx_notify_masked == true and does nothing, or it calls
    napi_schedule_prep() and sets MISSED.
P2: NAPI kthread.  When napi_complete_done() finds MISSED, it polls
    once more.

The kthread can read SCHED_THREADED from a value that the second
producer wrote (MISSED added on top of SCHED_THREADED).  The smp_wmb()
must still order the first producer's rx_notify_masked store.

Not modelled: after a MISSED poll the kthread sets and tests
SCHED_THREADED itself.  Both run on the same CPU.

""" + MODE_DOC[mode], BAD_STUCK, EXISTS_STUCK, init, [a, b, k])

    # --- two producers; the second one can start a new NAPI cycle --------
    for mode, result in (("nobarrier", "Sometimes"), ("wmb", "Never")):
        flush_wmb, rearm_wmb = MODES[mode]
        a = Thread()
        veth_xdp_flush(a, flush_wmb)
        b = Thread()
        veth_xdp_flush(b, flush_wmb)
        k = Thread()
        napi_kthread(k, missed="stop", cycles=2)
        add("veth-two-cycles+" + mode, result, """
Two producers and the NAPI kthread, two NAPI cycles.

P0, P1: producers in __veth_xdp_flush().
P2: NAPI kthread.  It waits for SCHED_THREADED and polls, two times.
    The second producer can take SCHED after the kthread completed
    the first poll.

When napi_complete_done() finds MISSED, the kthread stops and the
test ends.  veth-two-producers covers that case.

""" + MODE_DOC[mode], BAD_STUCK, EXISTS_STUCK, init, [a, b, k],
            slow="about 10 minutes")

    # --- veth_poll() re-arm from busy_poll_stop() -> NAPI kthread --------
    busy_init = ["atomic_t state = ATOMIC_INIT(1);", "int masked = 0;",
                 "int ring = 1;"]
    for mode, result in (("nobarrier", "Sometimes"),
                         ("flush-only", "Sometimes"), ("helper", "Never")):
        flush_wmb, rearm_wmb = MODES[mode]
        b = Thread()
        veth_poll_tail(b, OWNED_SCHED, ring=True, rearm_wmb=rearm_wmb)
        k = Thread()
        napi_kthread(k, ring=True, rearm_wmb=rearm_wmb)
        add("veth-busypoll-rearm+" + mode, result, """
The re-arm path of veth_poll() on a CPU that is not the NAPI kthread.

With socket busy polling, busy_poll_stop() calls veth_poll() on the
CPU of the application.

P0: end of veth_poll(), called from busy_poll_stop().  It owns SCHED
    (state starts at 1).  An entry arrived in the ring after
    veth_xdp_rcv() returned (ring starts at 1).  The ring check
    re-arms NAPI: rx_notify_masked = true, then SCHED_THREADED.
P1: NAPI kthread that is awake, one poll.

""" + MODE_DOC[mode], BAD_STUCK_OR_LOST, EXISTS_STUCK_OR_LOST,
            busy_init, [b, k])

    # --- busy_poll_stop() re-arm + producer -> NAPI kthread --------------
    for mode, result in (("nobarrier", "Sometimes"),
                         ("flush-only", "Sometimes"), ("helper", "Never")):
        flush_wmb, rearm_wmb = MODES[mode]
        b = Thread()
        veth_poll_tail(b, OWNED_SCHED, ring=True, rearm_wmb=rearm_wmb)
        p = Thread()
        veth_xdp_flush(p, flush_wmb, ring=True)
        k = Thread()
        napi_kthread(k, missed="repoll")
        add("veth-busypoll-rearm-producer+" + mode, result, """
As veth-busypoll-rearm, with the producer of the ring entry.

P0: end of veth_poll(), called from busy_poll_stop().  It owns SCHED
    (state starts at 1).
P1: producer: ptr_ring_produce(), then __veth_xdp_flush().
P2: NAPI kthread.  When napi_complete_done() finds MISSED, it polls
    once more.

P0 and P1 can both try to take SCHED.  The loser sets MISSED.

Not modelled: the kthread does not consume the ring entry.  P0 can
then re-arm NAPI in more cases than in the kernel.

""" + MODE_DOC[mode], BAD_STUCK, EXISTS_STUCK,
            ["atomic_t state = ATOMIC_INIT(1);", "int masked = 0;",
             "int ring = 0;"], [b, p, k], slow="about 15 minutes")

    return out


# ---------------------------------------------------------------------------
# arm64 instruction-level tests
# ---------------------------------------------------------------------------

A64_SCHED = 1
A64_SCHED_THREADED = 512            # BIT(NAPI_STATE_SCHED_THREADED), bit 9
A64_OWNED = A64_SCHED | A64_SCHED_THREADED


def a64_producer(lse, barrier):
    code = []
    if lse:
        code += ["MOV X3,#0",
                 "MOV X4,#%d" % A64_SCHED,
                 "CASAL X3,X4,[X2]",
                 "CBNZ X3,LC00"]
    else:
        code += ["LDXR X3,[X2]",
                 "CBNZ X3,LC00",
                 "MOV X4,#%d" % A64_SCHED,
                 "STLXR W5,X4,[X2]",
                 "CBNZ W5,LC00",
                 "DMB ISH"]
    code += ["MOV W6,#1",
             "STRB W6,[X1]"]
    if barrier:
        code += ["DMB ISHST"]
    if lse:
        code += ["MOV X7,#%d" % A64_SCHED_THREADED,
                 "STSET X7,[X2]"]
    else:
        code += ["LDXR X7,[X2]",
                 "ORR X7,X7,#%d" % A64_SCHED_THREADED,
                 "STXR W8,X7,[X2]"]
    code += ["LC00:"]
    return code


def a64_kthread(lse, ordered=True):
    code = ["LDR X3,[X2]",
            "TBZ X3,#9,LC10"]
    if lse:
        code += ["MOV X4,#%d" % A64_OWNED,
                 "MOV X5,#0",
                 "%s X4,X5,[X2]" % ("CASAL" if ordered else "CAS"),
                 "CMP X4,#%d" % A64_OWNED,
                 "B.NE LC10"]
    else:
        code += ["LDXR X4,[X2]",
                 "CMP X4,#%d" % A64_OWNED,
                 "B.NE LC10",
                 "MOV X5,#0",
                 "STLXR W6,X5,[X2]",
                 "CBNZ W6,LC10",
                 "DMB ISH"]
    code += ["STRB W5,[X1]",
             "DMB ISH",
             "LC10:"]
    return code


A64_LSE_DOC = """\
P0: producer in __veth_xdp_flush()
    CASAL      napi_schedule_prep(): cmpxchg() takes SCHED
    STRB       WRITE_ONCE(rq->rx_notify_masked, true)
%s    STSET      set_bit(NAPI_STATE_SCHED_THREADED)
P1: NAPI kthread that is awake
    LDR, TBZ   test_bit(NAPI_STATE_SCHED_THREADED)
    %-10s napi_complete_done(): cmpxchg() clears SCHED and
               SCHED_THREADED
    STRB       smp_store_mb(rq->rx_notify_masked, false)
    DMB ISH"""

A64_LLSC_DOC = """\
P0: producer in __veth_xdp_flush()
    LDXR, STLXR, DMB ISH   napi_schedule_prep(): cmpxchg() takes SCHED
    STRB                   WRITE_ONCE(rq->rx_notify_masked, true)
%s    LDXR, ORR, STXR        set_bit(NAPI_STATE_SCHED_THREADED)
P1: NAPI kthread that is awake
    LDR, TBZ               test_bit(NAPI_STATE_SCHED_THREADED)
    LDXR, STLXR, DMB ISH   napi_complete_done(): cmpxchg() clears SCHED
                           and SCHED_THREADED
    STRB                   smp_store_mb(rq->rx_notify_masked, false)
    DMB ISH

The kernel retries a failed store-exclusive.  The test does not: the
thread ends, and that execution cannot reach the bad state."""

A64_TAIL_DOC = """\
Bad state: NAPI is idle (state == 0) and rx_notify_masked is still
true.

napi->state uses the kernel bit values: SCHED = 0x1,
SCHED_THREADED = 0x200."""


A64_VIA_MISSED_DOC = """\
The kthread sees SCHED_THREADED in a value that another CPU wrote.
This is the LKMM test veth-handoff-via-missed as arm64 instructions,
for a CPU with LSE atomics.

The test starts after the first producer took SCHED (state starts
at 0x1).

P0: first producer
    STRB       WRITE_ONCE(rq->rx_notify_masked, true)
%s    STSET      set_bit(NAPI_STATE_SCHED_THREADED)
P1: second producer
    CASAL      napi_schedule_prep(): cmpxchg() sets MISSED.  It
               succeeds only on top of P0's STSET (0x201 -> 0x203).
P2: NAPI kthread
    LDR, TBZ   test_bit(NAPI_STATE_SCHED_THREADED)
    STRB       smp_store_mb(rq->rx_notify_masked, false)
    DMB ISH"""

A64_VIA_MISSED_TAIL_DOC = """\
Bad state: the kthread read state == 0x203 (515), so it saw
SCHED_THREADED through P1's update.  It cleared rx_notify_masked.  But
rx_notify_masked is true at the end: P0's store landed last.

napi->state uses the kernel bit values: SCHED = 0x1, MISSED = 0x2,
SCHED_THREADED = 0x200."""


def a64_render(name, result, title, doc, threads, state_init=0,
               exists=EXISTS_STUCK, tail_doc=A64_TAIL_DOC):
    width = max(len(i) for th in threads for i in th)
    rows = max(len(th) for th in threads)
    out = ["AArch64 %s" % name, '"%s"' % title, "(*", " * Result: %s" % result,
           " *"]
    for line in (doc.strip("\n") + "\n\n" + tail_doc).split("\n"):
        out.append((" * " + line).rstrip())
    out += [" *)", "{", "uint64_t state=%d; uint8_t masked=0;" % state_init]
    for i in range(len(threads)):
        out.append("%d:X1=masked; %d:X2=state;" % (i, i))
    out.append("}")
    cols = [["P%d" % i] + th + [""] * (rows - len(th))
            for i, th in enumerate(threads)]
    for r in range(rows + 1):
        out.append(" " + " | ".join(c[r].ljust(width) for c in cols) + " ;")
    out.append("exists (%s)" % exists)
    return "\n".join(out) + "\n"


def a64_tests():
    out = []
    for barrier, mode, result in ((False, "nobarrier", "Sometimes"),
                                  (True, "dmb-ishst", "Never")):
        wmb = "    DMB ISHST  smp_wmb(): the fix\n" if barrier else ""
        name = "veth-a64-lse+" + mode
        out.append((name, a64_render(
            name, result,
            "veth-handoff as arm64 code with LSE atomics, %s" %
            ("with smp_wmb()" if barrier else "no barrier"),
            "The veth-handoff race as arm64 instructions.  The CPU has LSE\n"
            "atomics (ARMv8.1 and later).\n\n" +
            A64_LSE_DOC % (wmb, "CASAL"),
            [a64_producer(True, barrier), a64_kthread(True)])))

    name = "veth-a64-lse-ctrl-dep+dmb-ishst"
    out.append((name, a64_render(
        name, "Never",
        "veth-a64-lse+dmb-ishst with an unordered CAS in the kthread",
        "Same as veth-a64-lse+dmb-ishst, but napi_complete_done() uses CAS\n"
        "here.  CAS has no acquire or release ordering.  The kernel uses\n"
        "CASAL.\n\n"
        "This shows that the control dependency from test_bit() alone\n"
        "already orders the kthread's rx_notify_masked = false store.\n\n" +
        A64_LSE_DOC % ("    DMB ISHST  smp_wmb(): the fix\n", "CAS"),
        [a64_producer(True, True), a64_kthread(True, ordered=False)])))

    a64_missed = A64_SCHED | 2 | A64_SCHED_THREADED     # 0x203
    for barrier, mode, result in ((False, "nobarrier", "Sometimes"),
                                  (True, "dmb-ishst", "Never")):
        wmb = "    DMB ISHST  smp_wmb(): the fix\n" if barrier else ""
        p0 = ["MOV W6,#1", "STRB W6,[X1]"]
        if barrier:
            p0 += ["DMB ISHST"]
        p0 += ["MOV X7,#%d" % A64_SCHED_THREADED, "STSET X7,[X2]"]
        p1 = ["MOV X3,#%d" % A64_OWNED, "MOV X4,#%d" % a64_missed,
              "CASAL X3,X4,[X2]"]
        p2 = ["LDR X3,[X2]", "TBZ X3,#9,LC20", "MOV W5,#0", "STRB W5,[X1]",
              "DMB ISH", "LC20:"]
        name = "veth-a64-lse-via-missed+" + mode
        out.append((name, a64_render(
            name, result,
            "veth-handoff-via-missed as arm64 code with LSE atomics, %s" %
            ("with smp_wmb()" if barrier else "no barrier"),
            A64_VIA_MISSED_DOC % wmb, [p0, p1, p2],
            state_init=A64_SCHED,
            exists="2:X3=%d /\\ masked=1" % a64_missed,
            tail_doc=A64_VIA_MISSED_TAIL_DOC)))

    for barrier, mode, result in ((False, "nobarrier", "Sometimes"),
                                  (True, "dmb-ishst", "Never")):
        wmb = ("    DMB ISHST              smp_wmb(): the fix\n"
               if barrier else "")
        name = "veth-a64-llsc+" + mode
        out.append((name, a64_render(
            name, result,
            "veth-handoff as arm64 code with LL/SC atomics, %s" %
            ("with smp_wmb()" if barrier else "no barrier"),
            "The veth-handoff race as arm64 instructions.  The CPU has no LSE\n"
            "atomics, so the kernel uses load-exclusive and store-exclusive.\n\n" +
            A64_LLSC_DOC % wmb,
            [a64_producer(False, barrier), a64_kthread(False)])))
    return out


# ---------------------------------------------------------------------------

def main():
    check = "--check" in sys.argv[1:]
    if [a for a in sys.argv[1:] if a != "--check"]:
        sys.exit(__doc__)

    stale = 0
    for subdir, tests in (("lkmm", lkmm_tests()), ("aarch64", a64_tests())):
        outdir = os.path.join(HERE, "litmus", subdir)
        os.makedirs(outdir, exist_ok=True)
        wanted = set()
        for name, text in tests:
            fname = name + ".litmus"
            wanted.add(fname)
            path = os.path.join(outdir, fname)
            if check:
                old = open(path).read() if os.path.exists(path) else None
                if old != text:
                    print("differs: %s" % os.path.relpath(path, HERE))
                    stale += 1
            else:
                with open(path, "w") as f:
                    f.write(text)
        for fname in sorted(os.listdir(outdir)):
            if fname.endswith(".litmus") and fname not in wanted:
                print("not generated by this script: litmus/%s/%s" %
                      (subdir, fname))
                stale += 1
    if check:
        print("litmus files %s gen-litmus.py" %
              ("DIFFER from" if stale else "match"))
    sys.exit(1 if stale else 0)


if __name__ == "__main__":
    main()
