#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Adversarial cheap-traffic test for veth BQL.
#
# Hypothesis (from the BQL/DQL simulator, see bql_simulator/FINDINGS.md):
#   DQL grows the limit fast (on any drain that empties the queue) but shrinks it
#   slowly (gated to once per slack_hold_time = 1s, using the minimum slack).
#   So per-packet COST VARIANCE ratchets the limit up toward ~2x the largest
#   burst.  An attacker can manufacture that variance with EASY-to-process
#   packets: packets that match an early-ACCEPT iptables rule skip the expensive
#   chain, so a coalescing window packs a huge completion count -> the limit
#   inflates -> the in-flight queue deepens -> latency-sensitive traffic (ping)
#   suffers.
#
# This test sets up:
#   - N filler iptables rules  (-d IP_B, no target)  -> expensive path (full walk)
#   - one early ACCEPT rule for a "cheap" UDP port    -> cheap path (1 rule)
# then compares ping RTT and the BQL limit between:
#   PHASE 1 baseline    : expensive flood + ping + a few short bursts to a 3rd
#                         port that ALSO walks the full chain (control: same
#                         fq_codel flow count, but NO BQL inflation)
#   PHASE 2 adversarial : expensive flood + ping + the same bursts aimed at the
#                         early-ACCEPT cheap port (inflation)
#
# Both phases have the SAME number of fq_codel flows (3), so differencing them
# isolates the BQL cost-variance effect from the plain DRR/quantum cost of adding
# a third flow.  Expected: the limit and ping RTT rise in PHASE 2 only.  The
# effect grows with tx-usecs (the coalescing window): modest at the 100us
# default, severe beyond.
#
# --xdp-drop: replace the iptables early-ACCEPT cheap path with an XDP_DROP program
# attached to the consumer (VETH_B).  XDP frees the cheap packet pre-GRO (~200ns vs
# ~770ns for iptables), so ~4x more cheap packets fit per coalescing window -> the
# limit pumps past the 256-entry ptr_ring ceiling even at the DEFAULT tx-usecs=100,
# which the iptables path cannot.  See XDP_DROP_TASK.md.  (Requires: make xdp.)
#
# Must run as root (creates netns/veth, loads iptables, tweaks sysctls).

SCRIPTDIR="$(cd "$(dirname -- "$0")" && pwd)"
cd "$SCRIPTDIR" || exit 1
source lib.sh

# Defaults
DURATION=15
NRULES=2500          # expensive-chain length (consumer slowdown)
QDISC=fq_codel
TX_USECS=100         # BQL coalescing window (the patch default; try 500/1000 for worse)
EXPENSIVE_PORT=9999  # walks the full filler chain
CHEAP_PORT=9998      # matched by the early ACCEPT rule (needs xt_tcpudp / CONFIG_NETFILTER_XTABLES)
CONTROL_PORT=9997    # baseline burst: a 3rd flow that still walks the full chain
                     # (no early ACCEPT) -> equal fq_codel flow count, NO BQL inflation
CHEAP_SIZE=64        # small packets => high cheap pps => big cheap-window bursts
CHEAP_BURST_SEC=1    # length of each cheap burst (not a sustained flow!)
CHEAP_BURSTS=5       # number of cheap bursts spread across the run
PKT_SIZE=1400
XDP_DROP=0           # 1 = drop cheap packets with XDP (before GRO) instead of the
                     # iptables early-ACCEPT -> cheaper, defeats BQL at tx-usecs=100
XDP_OBJ="./xdp_drop_cheap.o"  # built by: make xdp  (CHEAP_PORT is compiled in!)

VETH_A="veth_bql0"
VETH_B="veth_bql1"
IP_A="10.99.0.1"
IP_B="10.99.0.2"      # expensive: walks the full filler chain
IP_CHEAP="10.99.0.3"  # cheap: matched by the early ACCEPT rule (skips the chain)

usage() {
    echo "Usage: $0 [options]"
    echo "  --duration SEC    per-phase duration (default: $DURATION)"
    echo "  --nrules N        expensive-chain rules (default: $NRULES)"
    echo "  --qdisc NAME      qdisc (default: $QDISC)"
    echo "  --tx-usecs N      BQL coalescing window in us (default: $TX_USECS)"
    echo "  --cheap-size N    cheap-flood packet size (default: $CHEAP_SIZE)"
    echo "  --cheap-bursts N  number of cheap bursts across the run (default: $CHEAP_BURSTS)"
    echo "  --xdp-drop        drop cheap packets via XDP (pre-GRO) instead of"
    echo "                    iptables early-ACCEPT; defeats BQL at tx-usecs=100"
    exit 1
}
while [ $# -gt 0 ]; do
    case "$1" in
    --duration)   DURATION="$2"; shift 2 ;;
    --nrules)     NRULES="$2"; shift 2 ;;
    --qdisc)      QDISC="$2"; shift 2 ;;
    --tx-usecs)   TX_USECS="$2"; shift 2 ;;
    --cheap-size) CHEAP_SIZE="$2"; shift 2 ;;
    --cheap-bursts) CHEAP_BURSTS="$2"; shift 2 ;;
    --xdp-drop)   XDP_DROP=1; shift ;;
    --help|-h)    usage ;;
    *)            echo "unknown option: $1"; usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }
for t in udp_flood; do [ -x "./$t" ] || { echo "build first: make"; exit 1; }; done
[ "$XDP_DROP" -eq 1 ] && [ ! -f "$XDP_OBJ" ] && { echo "build first: make xdp ($XDP_OBJ missing)"; exit 1; }

BQL_DIR="/sys/class/net/${VETH_A}/queues/tx-0/byte_queue_limits"
WORK=$(mktemp -d)

cleanup() {
    pkill -f "udp_flood $IP_B" 2>/dev/null
    pkill -f "ping .* $IP_B" 2>/dev/null
    # Detach XDP before tearing down (netns delete would remove it too, but be tidy).
    [ -n "$NS" ] && ip -netns "$NS" link set dev "$VETH_B" xdpgeneric off 2>/dev/null
    [ -n "$NS" ] && ip -netns "$NS" link set dev "$VETH_B" xdp off 2>/dev/null
    tc qdisc del dev "$VETH_A" root 2>/dev/null
    ip link del "$VETH_A" 2>/dev/null
    [ -n "$NS" ] && ip netns del "$NS" 2>/dev/null
    [ -n "$ORIG_WMEM" ] && sysctl -qw net.core.wmem_max="$ORIG_WMEM"
    rm -rf "$WORK"
}
trap cleanup EXIT

setup() {
    setup_ns NS || exit 1
    ip link add "$VETH_A" type veth peer name "$VETH_B"
    ip link set "$VETH_B" netns "$NS"
    ip addr add "${IP_A}/24" dev "$VETH_A"; ip link set "$VETH_A" up
    ip -netns "$NS" addr add "${IP_B}/24" dev "$VETH_B"
    ip -netns "$NS" link set "$VETH_B" up

    ORIG_WMEM=$(sysctl -n net.core.wmem_max)
    sysctl -qw net.core.wmem_max=1048576
    sysctl -qw net.core.gro_normal_batch=8

    ethtool -K "$VETH_A" gro on tso off gso off 2>/dev/null
    ip netns exec "$NS" ethtool -K "$VETH_B" gro on tso off gso off 2>/dev/null
    # Threaded NAPI: producer/consumer on separate CPUs so BQL actually engages.
    echo 1 > /sys/class/net/"$VETH_A"/threaded 2>/dev/null
    ip netns exec "$NS" sh -c "echo 1 > /sys/class/net/$VETH_B/threaded" 2>/dev/null

    tc qdisc replace dev "$VETH_A" root $QDISC
    ip netns exec "$NS" tc qdisc replace dev "$VETH_B" root $QDISC

    # BQL coalescing window (patch 5).
    ethtool -C "$VETH_A" tx-usecs "$TX_USECS" 2>/dev/null || \
        echo "WARN: ethtool -C tx-usecs unsupported (old kernel?)"
}

# Attach the XDP_DROP program to the CONSUMER (VETH_B, in the netns).  Prefer
# native xdp; fall back to xdpgeneric.  Abort loudly on failure so an invalid run
# can't masquerade as a real one (mirrors the iptables guard).
attach_xdp() {
    if ip -netns "$NS" link set dev "$VETH_B" xdp obj "$XDP_OBJ" sec xdp 2>/dev/null; then
        echo "xdp: NATIVE attach on $VETH_B (drops udp/$CHEAP_PORT pre-GRO)"
    elif ip -netns "$NS" link set dev "$VETH_B" xdpgeneric obj "$XDP_OBJ" sec xdp 2>/dev/null; then
        echo "xdp: GENERIC attach on $VETH_B (native unsupported; smaller pump)"
    else
        echo "ERROR: failed to attach XDP ($XDP_OBJ) to $VETH_B" >&2
        echo "       need clang-built obj (make xdp) + iproute2 w/ libbpf + XDP support" >&2
        exit 1
    fi
}

setup_rules() {
    # Filler rules first: every packet to IP_B walks all N (expensive path).
    # These are the EXPENSIVE/victim path and stay in BOTH modes -- XDP only
    # replaces the *cheap* path (the early-ACCEPT).
    ip netns exec "$NS" bash -c '
        iptables-restore <<EOF
*filter
$(for n in $(seq 1 '"$NRULES"'); do echo "-I INPUT -d '"$IP_B"'"; done)
COMMIT
EOF'
    if [ "$XDP_DROP" -eq 1 ]; then
        # Cheap path = XDP_DROP before GRO (~200ns, no append). The cheap flood to
        # CHEAP_PORT is dropped on VETH_B's NAPI, but the BQL charge already
        # completed -> limit pumps. No iptables ACCEPT and no socket sink needed.
        attach_xdp
        echo "rules: $NRULES filler + XDP_DROP(udp/$CHEAP_PORT) on $VETH_B"
    else
        # Cheap path = iptables early ACCEPT at the very top: cheap-port packets
        # match rule 1 and skip the chain (the "matches the first rule" path).
        ip netns exec "$NS" iptables -I INPUT 1 -p udp --dport "$CHEAP_PORT" -j ACCEPT
        echo "rules: $NRULES filler + 1 early-ACCEPT(udp/$CHEAP_PORT)"
    fi
}

# Background-sample the BQL limit while traffic runs.
sample_limit() {  # $1 = outfile
    ( while :; do cat "$BQL_DIR/limit" 2>/dev/null; sleep 0.1; done ) > "$1" &
    echo $!
}

stats() {  # $1 = ping.log  $2 = limit samples -> prints "avg p99 max limitMax"
    grep -oP 'time=\K[0-9.]+' "$1" | sort -n > "$WORK/r"
    awk '{a[NR]=$1}
        END{
            n=NR; if(!n){printf "0 0 0"; exit}
            s=0; for(i=1;i<=n;i++) s+=a[i];
            idx=int(0.99*n); if(idx<1) idx=1;
            printf "%.3f %.3f %.3f", s/n, a[idx], a[n];
        }' "$WORK/r"
    printf " %d" "$(sort -n "$2" 2>/dev/null | tail -1)"
}

run_phase() {  # $1 = name  $2 = burst_port  $3 = burst_tag
    local name="$1" bport="$2" btag="$3" plog="$WORK/ping.$name" llog="$WORK/lim.$name"
    local spid ppid bpid
    spid=$(sample_limit "$llog")
    ping -i 0.01 -w "$DURATION" "$IP_B" > "$plog" 2>&1 & ppid=$!
    ./udp_flood "$IP_B" "$PKT_SIZE" "$EXPENSIVE_PORT" "$DURATION" "" expensive >/dev/null 2>&1 &
    # Both phases fire an identical extra burst (same size/rate/schedule) so the
    # fq_codel flow count matches -- baseline aims it at CONTROL_PORT (walks the
    # full chain, low completion-count-per-window => NO BQL inflation), adversarial
    # aims it at CHEAP_PORT (early ACCEPT, huge completion count => limit inflates).
    # Differencing the two phases isolates the BQL effect from the flow-count
    # (DRR quantum) effect of adding a third flow.
    #
    # Each burst pumps (or doesn't) the DQL limit, then stops; an inflated limit
    # stays up for ~1s (slack-hold) during which the expensive flood fills the
    # now-deep device FIFO, so ping queues behind a deep pile of SLOW packets.
    # Repeating re-arms that inflation throughout the phase.
    #
    # Bursts target i*DURATION/(CHEAP_BURSTS+1) for i=1..N.  Each burst blocks for
    # CHEAP_BURST_SEC, so we sleep relative to the real elapsed time (clamped >=0)
    # instead of a fixed gap, to keep the targets on schedule.
    ( elapsed=0
      for i in $(seq 1 "$CHEAP_BURSTS"); do
          at=$(( i * DURATION / (CHEAP_BURSTS + 1) ))
          gap=$(( at - elapsed ))
          [ "$gap" -gt 0 ] && { sleep "$gap"; elapsed=$(( elapsed + gap )); }
          ./udp_flood "$IP_B" "$CHEAP_SIZE" "$bport" "$CHEAP_BURST_SEC" "" "$btag"
          elapsed=$(( elapsed + CHEAP_BURST_SEC ))
      done
    ) >/dev/null 2>&1 &
    bpid=$!
    wait "$ppid"
    sleep 1; kill "$spid" "$bpid" 2>/dev/null
    pkill -f "udp_flood $IP_B" 2>/dev/null
    # Export raw per-phase samples so a sweep can POOL them across runs and take a
    # stable high percentile (mean-of-per-run-max is a single-packet estimator).
    if [ -n "$SAMPLES_DIR" ]; then
        mkdir -p "$SAMPLES_DIR"
        grep -oP 'time=\K[0-9.]+' "$plog" > "$SAMPLES_DIR/rtt.$name" 2>/dev/null
        cp "$llog" "$SAMPLES_DIR/lim.$name" 2>/dev/null
    fi
    echo "$name $(stats "$plog" "$llog")"
}

# --- main ---
echo "=== veth BQL adversarial cheap-traffic test ==="
echo "duration=${DURATION}s nrules=$NRULES qdisc=$QDISC tx-usecs=$TX_USECS cheap-path=$([ "$XDP_DROP" -eq 1 ] && echo XDP_DROP || echo iptables-ACCEPT)"
setup
setup_rules
echo ""

# Both phases run an identical 3rd-flow burst; only the burst's PORT differs
# (control = expensive chain, no inflation;  cheap = early ACCEPT, inflation).
B=$(run_phase baseline    "$CONTROL_PORT" control)
A=$(run_phase adversarial "$CHEAP_PORT"   cheap)

read -r _ b_avg b_p99 b_max b_lim <<< "$B"
read -r _ a_avg a_p99 a_max a_lim <<< "$A"

printf "\n%-12s %10s %10s %10s %10s\n" "phase" "rtt_avg" "rtt_p99" "rtt_max" "limit_max"
printf "%-12s %10s %10s %10s %10s\n" "baseline"    "$b_avg" "$b_p99" "$b_max" "$b_lim"
printf "%-12s %10s %10s %10s %10s\n" "adversarial" "$a_avg" "$a_p99" "$a_max" "$a_lim"
awk -v bm="$b_max" -v am="$a_max" -v bl="$b_lim" -v al="$a_lim" 'BEGIN{
    printf "\nlimit inflated x%.1f, ping RTT(max) spiked x%.1f  (transient, ~1s after each burst)\n",
        (bl?al/bl:0), (bm?am/bm:0);
}'
echo "(the spike is in rtt_max/p99, not avg -- it recurs for ~1s after each burst while DQL holds the inflated limit)"
echo "(larger --tx-usecs makes it worse; see FINDINGS.md section 10)"
