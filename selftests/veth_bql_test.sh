#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Veth BQL (Byte Queue Limits) stress test and A/B benchmarking tool.
#
# Creates a veth pair with GRO on and TSO off (ensures all packets use
# the NAPI/ptr_ring path where BQL operates), attaches a configurable
# qdisc, optionally loads iptables rules to slow the consumer NAPI
# processing, and floods UDP packets at maximum rate.
#
# Primary uses:
#   1) A/B comparison of latency with/without BQL (--bql-disable flag)
#   2) Testing different qdiscs and their parameters (--qdisc, --qdisc-opts)
#   3) Detecting kernel BUG/Oops from DQL accounting mismatches
#
# Key design detail -- SO_SNDBUF and wmem_max:
#   The UDP sendto() path charges each SKB to the socket's sk_wmem_alloc
#   counter.  The SKB carries a destructor (sock_wfree) that releases the
#   charge only after the consumer NAPI thread on the peer veth finishes
#   processing it -- including any iptables rules in the receive path.
#   With the default sk_sndbuf (~208KB from wmem_default), only ~93
#   packets (1442B each) can be in-flight before sendto() returns EAGAIN.
#   Since 93 < 256 ptr_ring entries, the ring never fills and no qdisc
#   backpressure occurs.  The test temporarily raises the global wmem_max
#   sysctl and sets SO_SNDBUF=1MB to allow enough in-flight SKBs to
#   saturate the ptr_ring.  The original wmem_max is restored on exit.
#
# Two TX-stop mechanisms and the dark-buffer problem:
#   DRV_XOFF backpressure (commit dc82a33297fc) stops the TX queue when
#   the 256-entry ptr_ring is full.  The queue is released at the end of
#   veth_poll() (commit 5442a9da6978) after processing up to 64 packets
#   (NAPI budget).  Without BQL, the entire ring is a FIFO "dark buffer"
#   in front of the qdisc -- packets there are invisible to AQM.
#
#   BQL adds STACK_XOFF, which dynamically limits in-flight bytes and
#   stops the queue *before* the ring fills.  This keeps the ring
#   shallow and moves buffering into the qdisc where sojourn-based AQM
#   (codel, fq_codel, CAKE/COBALT) can measure and drop packets.
#
# Sojourn time and NAPI budget interaction:
#   DRV_XOFF releases backpressure once per NAPI poll (up to 64 pkts).
#   During that cycle, packets queued in the qdisc accumulate sojourn
#   time.  With fq_codel's default target of 5ms, the threshold is:
#     5000us / 64 pkts = 78us/pkt --> ~12,800 pps consumer speed.
#   Below that rate the NAPI-64 cycle exceeds the target and fq_codel
#   starts dropping.  Use --nrules and --qdisc-opts to experiment.
#
SCRIPTDIR="$(cd "$(dirname -- "$0")" && pwd)"
cd "$SCRIPTDIR" || exit 1
source lib.sh

# Defaults
DURATION=30       # seconds; use longer --duration to reach DQL counter wrap
NRULES=3500       # iptables rules in consumer NS (0 to disable)
QDISC=sfq         # qdisc to use (sfq, pfifo, fq_codel, etc.)
QDISC_OPTS=""     # extra qdisc parameters (e.g. "target 1ms interval 10ms")
BQL_DISABLE=0     # 1 to disable BQL (sets limit_min high)
NORMAL_NAPI=0     # 1 to use normal softirq NAPI (skip threaded NAPI)
QDISC_REPLACE=0   # 1 to test qdisc replacement under active traffic
PING_ONLY=0       # 1 to measure baseline ping RTT (no flood traffic)
TINY_FLOOD=0      # 1 to add 2nd UDP thread with min-size packets
BQL_MIN_LIMIT=""   # set DQL limit_min (e.g. 8 for one cache-line of ptr_ring)
PRINT_HIST=0      # 1 to print bpftrace histograms at end
NO_BPFTRACE=0     # 1 to skip bpftrace histogram collection
BURST_SPEC=""     # burst spec 'N:Mus' e.g. '100:500' = 100 pkts then 500us pause
TX_USECS=""       # ethtool tx-usecs for BQL completion coalescing (0=per-pkt)
GRO_NORMAL_BATCH="" # override /proc/sys/net/core/gro_normal_batch
USE_PKTGEN=0      # 1 to use kernel pktgen instead of udp_flood
PKTGEN_SIZE=64    # pktgen packet size (default 64 for max pps)
PKTGEN_THREADS=1  # number of pktgen kernel threads
MQ_QUEUES=2       # multi-queue: number of TX/RX channels (0=single-queue)
VETH_A="veth_bql0"
VETH_B="veth_bql1"
IP_A="10.99.0.1"
IP_B="10.99.0.2"
PORT=9999
PKT_SIZE=1400     # large packets: slower producer, bigger BQL charges

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  --duration SEC   test duration (default: $DURATION)"
    echo "  --nrules N       iptables rules to slow consumer (default: $NRULES, 0=disable)"
    echo "  --qdisc NAME     qdisc to install (default: $QDISC)"
    echo "  --qdisc-opts STR extra qdisc params (e.g. 'target 1ms interval 10ms')"
    echo "  --bql-disable    disable BQL for A/B comparison"
    echo "  --normal-napi    use softirq NAPI instead of threaded NAPI"
    echo "  --qdisc-replace  test qdisc replacement under active traffic"
    echo "  --ping           measure baseline ping RTT (no flood traffic)"
    echo "  --tiny-flood     add 2nd UDP thread with min-size packets (stress BQL bytes)"
    echo "  --bql-min-limit N set DQL limit_min to N (e.g. 8 for cache-line ptr_ring)"
    echo "  --hist           print bpftrace histograms at end"
    echo "  --no-bpftrace    skip bpftrace histogram collection"
    echo "  --tx-usecs N     set ethtool tx-usecs for BQL coalescing (0=per-pkt, default=kernel)"
    echo "  --gro-normal-batch N  set /proc/sys/net/core/gro_normal_batch (default=kernel)"
    echo "  --burst N:Mus    bursty traffic: N pkts then M us pause (e.g. '100:500')"
    echo "  --pktgen         use kernel pktgen instead of udp_flood (kernel-space TX)"
    echo "  --pktgen-size N  pktgen packet size in bytes (default: $PKTGEN_SIZE)"
    echo "  --pktgen-threads N pktgen kernel threads (default: $PKTGEN_THREADS)"
    echo "  --single-queue   use single TX queue (skip MQ+XPS, default: MQ=$MQ_QUEUES)"
    echo "  --mq-queues N    set number of TX/RX channels (default: $MQ_QUEUES)"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
    --duration)   DURATION="$2"; shift 2 ;;
    --nrules)     NRULES="$2"; shift 2 ;;
    --qdisc)      QDISC="$2"; shift 2 ;;
    --qdisc-opts) QDISC_OPTS="$2"; shift 2 ;;
    --bql-disable) BQL_DISABLE=1; shift ;;
    --normal-napi) NORMAL_NAPI=1; shift ;;
    --qdisc-replace) QDISC_REPLACE=1; shift ;;
    --ping)       PING_ONLY=1; shift ;;
    --tiny-flood) TINY_FLOOD=1; shift ;;
    --bql-min-limit) BQL_MIN_LIMIT="$2"; shift 2 ;;
    --hist)       PRINT_HIST=1; shift ;;
    --no-bpftrace) NO_BPFTRACE=1; shift ;;
    --tx-usecs)   TX_USECS="$2"; shift 2 ;;
    --gro-normal-batch) GRO_NORMAL_BATCH="$2"; shift 2 ;;
    --burst)      BURST_SPEC="$2"; shift 2 ;;
    --pktgen)     USE_PKTGEN=1; shift ;;
    --pktgen-size)  PKTGEN_SIZE="$2"; shift 2 ;;
    --pktgen-threads) PKTGEN_THREADS="$2"; shift 2 ;;
    --single-queue) MQ_QUEUES=0; shift ;;
    --mq-queues)  MQ_QUEUES="$2"; shift 2 ;;
    --help|-h)    usage ;;
    *)            echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Derive active TX queue index from MQ setting
if [ "$MQ_QUEUES" -gt 0 ]; then
    MQ_TXQ=1
else
    MQ_TXQ=0
fi

# Results directory: use RESULTSDIR from env (set by virtme wrapper) or create one.
if [ -z "$RESULTSDIR" ]; then
    REPO_ROOT="$(dirname "$SCRIPTDIR")"
    RESULTSDIR="$REPO_ROOT/results/selftests/$(date +%Y-%m-%dT%H-%M-%S)"
    mkdir -p "$RESULTSDIR"
    ln -sfn "$(basename "$RESULTSDIR")" "$REPO_ROOT/results/selftests/latest"
    # Record command line for easy re-run (bare metal mode)
    echo "sudo $0 $*" > "$RESULTSDIR/cmdline.sh"
fi

FLOOD_PID=""
FLOOD2_PID=""
SINK_PID=""
PING_PID=""
BPFTRACE_PID=""
BPFTRACE2_PID=""
BPFTRACE3_PID=""
PKTGEN_TIMER_PID=""

# shellcheck disable=SC2329  # cleanup is invoked indirectly via trap
cleanup() {
    [ -n "$BPFTRACE3_PID" ] && kill_process "$BPFTRACE3_PID"
    [ -n "$BPFTRACE2_PID" ] && kill_process "$BPFTRACE2_PID"
    [ -n "$BPFTRACE_PID" ] && kill_process "$BPFTRACE_PID"
    if [ "$USE_PKTGEN" -eq 1 ]; then
        echo "stop" > /proc/net/pktgen/pgctrl 2>/dev/null || true
        [ -n "$PKTGEN_TIMER_PID" ] && kill_process "$PKTGEN_TIMER_PID"
        [ -n "$FLOOD_PID" ] && { wait "$FLOOD_PID" 2>/dev/null || true; }
        echo "reset" > /proc/net/pktgen/pgctrl 2>/dev/null || true
    else
        [ -n "$FLOOD_PID" ] && kill_process "$FLOOD_PID"
    fi
    [ -n "$FLOOD2_PID" ] && kill_process "$FLOOD2_PID"
    [ -n "$SINK_PID" ] && kill_process "$SINK_PID"
    [ -n "$PING_PID" ] && kill_process "$PING_PID"
    cleanup_all_ns
    ip link del "$VETH_A" 2>/dev/null || true
    [ -n "$ORIG_WMEM_MAX" ] && sysctl -qw net.core.wmem_max="$ORIG_WMEM_MAX"
    [ -n "$ORIG_GRO_NORMAL_BATCH" ] && sysctl -qw net.core.gro_normal_batch="$ORIG_GRO_NORMAL_BATCH"
    log_info "Results: $RESULTSDIR"
}
trap cleanup EXIT

require_command ethtool
require_command tc

# Verify pre-built binaries exist (not needed for pktgen or ping-only mode)
if [ "$USE_PKTGEN" -eq 0 ] && [ "$PING_ONLY" -eq 0 ]; then
    for tool in udp_flood udp_sink; do
        if [ ! -x "$SCRIPTDIR/$tool" ]; then
            echo "ERROR: $SCRIPTDIR/$tool not found. Run 'make -C $SCRIPTDIR' first." >&2
            exit $ksft_fail
        fi
    done
fi

# --- Function definitions ---

setup_veth() {
    log_info "Setting up veth pair with GRO"
    setup_ns NS || exit $ksft_skip
    ip link add "$VETH_A" type veth peer name "$VETH_B" || \
        { echo "Failed to create veth pair (need root?)"; exit $ksft_skip; }
    ip link set "$VETH_B" netns "$NS" || \
        { echo "Failed to move veth to namespace"; exit $ksft_skip; }

    # Configure IPs
    ip addr add "${IP_A}/24" dev "$VETH_A"
    ip link set "$VETH_A" up

    ip -netns "$NS" addr add "${IP_B}/24" dev "$VETH_B"
    ip -netns "$NS" link set "$VETH_B" up

    # Raise wmem_max so the flood tool's SO_SNDBUF takes effect.
    # Default 212992 caps in-flight to ~93 packets (sk_wmem_alloc limit),
    # which is less than the 256-entry ptr_ring and prevents backpressure.
    ORIG_WMEM_MAX=$(sysctl -n net.core.wmem_max)
    sysctl -qw net.core.wmem_max=1048576

    # Always save so cleanup restores even if a previous run changed it
    ORIG_GRO_NORMAL_BATCH=$(sysctl -n net.core.gro_normal_batch)
    if [ -n "$GRO_NORMAL_BATCH" ]; then
        sysctl -qw net.core.gro_normal_batch="$GRO_NORMAL_BATCH"
    fi

    # Enable GRO on both ends -- activates NAPI -- BQL code path
    ethtool -K "$VETH_A" gro on 2>/dev/null || true
    ip netns exec "$NS" ethtool -K "$VETH_B" gro on 2>/dev/null || true

    # Disable TSO so veth_skb_is_eligible_for_gro() returns true for all
    # packets, ensuring every SKB takes the NAPI/ptr_ring path.  With TSO
    # enabled, only packets matching sock_wfree + GRO features are eligible;
    # disabling TSO removes that filter unconditionally.
    ethtool -K "$VETH_A" tso off gso off 2>/dev/null || true
    ip netns exec "$NS" ethtool -K "$VETH_B" tso off gso off 2>/dev/null || true

    # Enable threaded NAPI -- this is critical: BQL backpressure (STACK_XOFF)
    # only engages when producer and consumer run on separate CPUs.
    # Without threaded NAPI, softirq completions happen too fast for BQL
    # to build up enough in-flight bytes to trigger the limit.
    if [ "$NORMAL_NAPI" -eq 0 ]; then
        echo 1 > /sys/class/net/"$VETH_A"/threaded 2>/dev/null || true
        ip netns exec "$NS" sh -c "echo 1 > /sys/class/net/$VETH_B/threaded" 2>/dev/null || true
        log_info "Threaded NAPI enabled"
    else
        log_info "Using normal softirq NAPI (threaded NAPI disabled)"
    fi

    # Multi-queue setup: activate MQ_QUEUES channels and use XPS to steer
    # all traffic to TX queue 1.  This deterministically triggers the veth
    # txq-wake bug (dc82a33297fc): veth_poll() for queue 1 incorrectly
    # wakes peer TX queue 0, so queue 1 stays stopped forever.
    # get_xps_queue() in netdev_pick_tx() runs before the flow-hash
    # fallback, making the steering deterministic.
    if [ "$MQ_QUEUES" -gt 0 ]; then
        ethtool --set-channels "$VETH_A" rx "$MQ_QUEUES" tx "$MQ_QUEUES" || \
            { log_info "WARNING: failed to set $MQ_QUEUES channels on $VETH_A"; }
        ip netns exec "$NS" ethtool --set-channels "$VETH_B" rx "$MQ_QUEUES" tx "$MQ_QUEUES" || \
            { log_info "WARNING: failed to set $MQ_QUEUES channels on $VETH_B"; }

        # XPS: clear queue 0, map all CPUs to queue 1
        local cpu_mask
        cpu_mask=$(printf "%x" $(( (1 << $(nproc)) - 1 )))
        echo 0 > /sys/class/net/"$VETH_A"/queues/tx-0/xps_cpus
        echo "$cpu_mask" > /sys/class/net/"$VETH_A"/queues/tx-1/xps_cpus
        log_info "MQ enabled: $MQ_QUEUES channels, XPS steering to tx-${MQ_TXQ}"
    fi
}

install_qdisc() {
    local qdisc="${1:-$QDISC}"
    local opts="${2:-}"
    # Add a qdisc -- veth defaults to noqueue, but BQL needs a qdisc
    # because STACK_XOFF is checked by the qdisc layer.
    # Note: qdisc_create() auto-fixes txqueuelen=0 on IFF_NO_QUEUE devices
    # to DEFAULT_TX_QUEUE_LEN (commit 84c46dd86538).
    log_info "Installing qdisc: $qdisc $opts"
    # shellcheck disable=SC2086  # $opts must word-split for tc arguments
    tc qdisc replace dev "$VETH_A" root $qdisc $opts
    # shellcheck disable=SC2086
    ip netns exec "$NS" tc qdisc replace dev "$VETH_B" root $qdisc $opts
}

remove_qdisc() {
    log_info "Removing qdisc (reverting to noqueue)"
    tc qdisc del dev "$VETH_A" root 2>/dev/null || true
    ip netns exec "$NS" tc qdisc del dev "$VETH_B" root 2>/dev/null || true
}

setup_iptables() {
    # Bulk-load iptables rules in consumer namespace to slow NAPI processing.
    # Many rules force per-packet linear rule traversal, increasing consumer
    # overhead and BQL inflight bytes -- simulates realistic k8s-like workload.
    # Uses filter/INPUT chain; verify_iptables_hit checks at runtime
    # whether rules are actually being evaluated.
    if [ "$NRULES" -gt 0 ]; then
        # shellcheck disable=SC2016  # single quotes intentional
        ip netns exec "$NS" bash -c '
        iptables-restore < <(
        echo "*filter"
        for n in $(seq 1 '"$NRULES"'); do
          echo "-I INPUT -d '"$IP_B"'"
        done
        echo "COMMIT"
        )
        ' 2>/dev/null || { RET=$ksft_fail retmsg="iptables not available" \
            log_test "iptables"; exit "$EXIT_STATUS"; }
        log_info "Loaded $NRULES iptables rules (filter/INPUT) in consumer NS"
    fi
}

verify_iptables_hit() {
    if [ "$NRULES" -eq 0 ]; then
        return 0
    fi
    local before after
    before=$(ip netns exec "$NS" iptables -L INPUT -v -n 2>/dev/null | \
        awk 'NR==3 {print $1}')
    sleep 1
    after=$(ip netns exec "$NS" iptables -L INPUT -v -n 2>/dev/null | \
        awk 'NR==3 {print $1}')
    if [ "$before" = "$after" ]; then
        log_info "WARNING: iptables rules not being evaluated (pkts=$after)"
        return 1
    fi
    log_info "iptables rules active (pkts: $before -> $after)"
    return 0
}

check_bql_sysfs() {
    BQL_DIR="/sys/class/net/${VETH_A}/queues/tx-${MQ_TXQ}/byte_queue_limits"
    if [ -d "$BQL_DIR" ]; then
        log_info "BQL sysfs found: $BQL_DIR"
        if [ "$BQL_DISABLE" -eq 1 ]; then
            echo 1073741824 > "$BQL_DIR/limit_min"
            log_info "BQL effectively disabled (limit_min=1G)"
        elif [ -n "$BQL_MIN_LIMIT" ]; then
            echo "$BQL_MIN_LIMIT" > "$BQL_DIR/limit_min"
            log_info "BQL limit_min set to $BQL_MIN_LIMIT"
        fi
    else
        log_info "BQL sysfs absent -- kernel likely missing veth BQL patchset"
        BQL_DIR=""
    fi
    if [ -n "$TX_USECS" ] && [ -n "$BQL_DIR" ]; then
        ip netns exec "$NS" ethtool -C "$VETH_B" tx-usecs "$TX_USECS" 2>/dev/null && \
            log_info "ethtool tx-usecs set to $TX_USECS on $VETH_B (rx side)" || \
            log_info "ethtool tx-usecs not supported (kernel missing coalescing patch?)"
    fi
}

pg_ctrl() {
    local proc_file="/proc/net/pktgen/pgctrl"
    echo "$1" > "$proc_file" || { echo "ERROR: pg_ctrl $1 failed" >&2; return 1; }
}

pg_thread() {
    local thread=$1; shift
    local proc_file="/proc/net/pktgen/kpktgend_${thread}"
    echo "$@" > "$proc_file" || { echo "ERROR: pg_thread $thread $@ failed" >&2; return 1; }
}

pg_set() {
    local dev=$1; shift
    local proc_file="/proc/net/pktgen/$dev"
    echo "$@" > "$proc_file" || { echo "ERROR: pg_set $dev $@ failed" >&2; return 1; }
}

start_traffic_pktgen() {
    # Snapshot dmesg before test
    DMESG_BEFORE=$(dmesg | wc -l)

    # Snapshot peer rx_packets before traffic starts -- used to compute
    # goodput (actually delivered packets) vs pktgen's enqueue count.
    # Dropping qdiscs like fq_codel inflate pktgen pps because CoDel drops
    # happen on dequeue (after pktgen counted the enqueue as "sent").
    RX_BEFORE=$(ip netns exec "$NS" cat /sys/class/net/"$VETH_B"/statistics/rx_packets 2>/dev/null) || RX_BEFORE=0

    # Uses pktgen "xmit_mode queue_xmit" to inject packets into the TX
    # qdisc egress path via __dev_queue_xmit().  This exercises the full
    # qdisc + BQL path without socket-layer gating (no sk_wmem_alloc).
    # See samples/pktgen/pktgen_bench_xmit_mode_queue_xmit.sh
    modprobe pktgen 2>/dev/null || \
        { echo "ERROR: pktgen module not available"; exit $ksft_skip; }

    [ -d "/proc/net/pktgen" ] || \
        { echo "ERROR: /proc/net/pktgen not found"; exit $ksft_skip; }

    local dst_mac
    dst_mac=$(ip netns exec "$NS" cat /sys/class/net/"$VETH_B"/address)

    # Reset any stale state from previous runs
    pg_ctrl "reset"

    local last_thread=$((PKTGEN_THREADS - 1))
    for ((thread = 0; thread <= last_thread; thread++)); do
        local dev="${VETH_A}@${thread}"
        # Each thread gets a different dst port so flows hash into
        # different qdisc buckets (e.g. fq_codel flow slots).
        local dst_port=$((PORT + thread))

        pg_thread $thread "rem_device_all"
        pg_thread $thread "add_device" $dev

        # Base config -- mirrors upstream pktgen_bench_xmit_mode_queue_xmit.sh
        pg_set $dev "flag QUEUE_MAP_CPU"
        pg_set $dev "flag NO_TIMESTAMP"
        pg_set $dev "count 0"
        pg_set $dev "pkt_size $PKTGEN_SIZE"
        pg_set $dev "delay 0"

        # Destination
        pg_set $dev "dst_mac $dst_mac"
        pg_set $dev "dst $IP_B"
        pg_set $dev "udp_dst_min $dst_port"
        pg_set $dev "udp_dst_max $dst_port"

        # Inject into TX qdisc path (not ndo_start_xmit directly)
        pg_set $dev "xmit_mode queue_xmit"
    done

    log_info "Starting ping to $IP_B (5/s) to measure latency under load"
    ping -i 0.2 -w "$DURATION" "$IP_B" > "$RESULTSDIR"/ping.log 2>&1 &
    PING_PID=$!

    # pg_ctrl "start" blocks in kernel until stopped or count reached.
    log_info "Starting pktgen queue_xmit on $VETH_A (threads=$PKTGEN_THREADS pkt_size=$PKTGEN_SIZE)"
    ( pg_ctrl "start" ) &
    FLOOD_PID=$!

    # Optional: start bpftrace histograms (best-effort)
    if [ "$NO_BPFTRACE" -eq 0 ] && command -v bpftrace >/dev/null 2>&1; then
        local bt_dir
        bt_dir="$(dirname -- "$0")"

        local bt_napi="${bt_dir}/napi_poll_hist.bt"
        if [ -f "$bt_napi" ]; then
            bpftrace "$bt_napi" > "$RESULTSDIR"/napi_poll.log 2>&1 &
            BPFTRACE_PID=$!
            log_info "bpftrace napi_poll histogram started (pid=$BPFTRACE_PID)"
        fi

        local bt_bql="${bt_dir}/veth_bql_inflight.bt"
        if [ -f "$bt_bql" ]; then
            bpftrace "$bt_bql" > "$RESULTSDIR"/bql_inflight.log 2>&1 &
            BPFTRACE2_PID=$!
            log_info "bpftrace BQL inflight histogram started (pid=$BPFTRACE2_PID)"
        fi

        local bt_interval="${bt_dir}/bql_interval.bt"
        if [ -f "$bt_interval" ]; then
            bpftrace "$bt_interval" > "$RESULTSDIR"/bql_interval.log 2>&1 &
            BPFTRACE3_PID=$!
            log_info "bpftrace BQL interval histogram started (pid=$BPFTRACE3_PID)"
        fi
    fi

    # Schedule a stop after DURATION seconds
    ( sleep "$DURATION"; pg_ctrl "stop" 2>/dev/null ) &
    PKTGEN_TIMER_PID=$!
}

stop_traffic_pktgen() {
    pg_ctrl "stop" 2>/dev/null || true
    [ -n "$PKTGEN_TIMER_PID" ] && kill_process "$PKTGEN_TIMER_PID"
    PKTGEN_TIMER_PID=""
    [ -n "$FLOOD_PID" ] && { wait "$FLOOD_PID" 2>/dev/null || true; }
    FLOOD_PID=""
    pg_ctrl "reset" 2>/dev/null || true
}

start_traffic() {
    # Snapshot dmesg before test
    DMESG_BEFORE=$(dmesg | wc -l)

    # Snapshot peer rx_packets for goodput calculation (see start_traffic_pktgen)
    RX_BEFORE=$(ip netns exec "$NS" cat /sys/class/net/"$VETH_B"/statistics/rx_packets 2>/dev/null) || RX_BEFORE=0

    log_info "Starting UDP sink in namespace"
    ip netns exec "$NS" "$SCRIPTDIR"/udp_sink "$PORT" "sink[${PKT_SIZE}B]" &
    SINK_PID=$!
    sleep 0.2

    log_info "Starting ping to $IP_B (5/s) to measure latency under load"
    ping -i 0.2 -w "$DURATION" "$IP_B" > "$RESULTSDIR"/ping.log 2>&1 &
    PING_PID=$!

    if [ -n "$BURST_SPEC" ]; then
        log_info "Flooding ${PKT_SIZE}-byte UDP packets for ${DURATION}s (burst ${BURST_SPEC})"
        "$SCRIPTDIR"/udp_flood "$IP_B" "$PKT_SIZE" "$PORT" "$DURATION" "" "flood[${PKT_SIZE}B]" "$BURST_SPEC" &
    else
        log_info "Flooding ${PKT_SIZE}-byte UDP packets for ${DURATION}s"
        "$SCRIPTDIR"/udp_flood "$IP_B" "$PKT_SIZE" "$PORT" "$DURATION" "" "flood[${PKT_SIZE}B]" &
    fi
    FLOOD_PID=$!

    # Optional: 2nd UDP thread with tiny packets to stress byte-based BQL.
    # Small packets charge few BQL bytes, letting many more into the
    # ptr_ring before STACK_XOFF fires -- exposing the dark buffer.
    if [ "$TINY_FLOOD" -eq 1 ]; then
        local port2=$((PORT + 1))
        ip netns exec "$NS" "$SCRIPTDIR"/udp_sink "$port2" "sink[24B]" &
        log_info "Starting 2nd UDP flood (min-size pkts) on port $port2"
        "$SCRIPTDIR"/udp_flood "$IP_B" 24 "$port2" "$DURATION" "" "flood[24B]" &
        FLOOD2_PID=$!
    fi

    # Optional: start bpftrace histograms (best-effort)
    if [ "$NO_BPFTRACE" -eq 0 ] && command -v bpftrace >/dev/null 2>&1; then
        local bt_dir
        bt_dir="$(dirname -- "$0")"

        local bt_napi="${bt_dir}/napi_poll_hist.bt"
        if [ -f "$bt_napi" ]; then
            bpftrace "$bt_napi" > "$RESULTSDIR"/napi_poll.log 2>&1 &
            BPFTRACE_PID=$!
            log_info "bpftrace napi_poll histogram started (pid=$BPFTRACE_PID)"
        fi

        local bt_bql="${bt_dir}/veth_bql_inflight.bt"
        if [ -f "$bt_bql" ]; then
            bpftrace "$bt_bql" > "$RESULTSDIR"/bql_inflight.log 2>&1 &
            BPFTRACE2_PID=$!
            log_info "bpftrace BQL inflight histogram started (pid=$BPFTRACE2_PID)"
        fi

        local bt_interval="${bt_dir}/bql_interval.bt"
        if [ -f "$bt_interval" ]; then
            bpftrace "$bt_interval" > "$RESULTSDIR"/bql_interval.log 2>&1 &
            BPFTRACE3_PID=$!
            log_info "bpftrace BQL interval histogram started (pid=$BPFTRACE3_PID)"
        fi
    fi
}

stop_traffic() {
    if [ "$USE_PKTGEN" -eq 1 ]; then
        stop_traffic_pktgen
    else
        [ -n "$FLOOD_PID" ] && kill_process "$FLOOD_PID"
        FLOOD_PID=""
    fi
    [ -n "$FLOOD2_PID" ] && kill_process "$FLOOD2_PID"
    FLOOD2_PID=""
    [ -n "$SINK_PID" ] && kill_process "$SINK_PID"
    SINK_PID=""
    [ -n "$PING_PID" ] && kill_process "$PING_PID"
    PING_PID=""
    [ -n "$BPFTRACE_PID" ] && kill_process "$BPFTRACE_PID"
    BPFTRACE_PID=""
    [ -n "$BPFTRACE2_PID" ] && kill_process "$BPFTRACE2_PID"
    BPFTRACE2_PID=""
    [ -n "$BPFTRACE3_PID" ] && kill_process "$BPFTRACE3_PID"
    BPFTRACE3_PID=""
}

check_dmesg_bug() {
    local bug_pattern='kernel BUG|BUG:|Oops:|BUG_ON.*dql_completed'
    local warn_pattern='WARNING:|asks to queue packet|NETDEV WATCHDOG'
    if dmesg | tail -n +$((DMESG_BEFORE + 1)) | \
       grep -qE "$bug_pattern"; then
        dmesg | tail -n +$((DMESG_BEFORE + 1)) | \
            grep -B2 -A20 -E "$bug_pattern|$warn_pattern"
        return 1
    fi
    # Log new warnings since last check (don't repeat old ones)
    local cur_lines
    cur_lines=$(dmesg | wc -l)
    if [ "$cur_lines" -gt "${DMESG_WARN_SEEN:-$DMESG_BEFORE}" ]; then
        local new_warns
        new_warns=$(dmesg | tail -n +$(("${DMESG_WARN_SEEN:-$DMESG_BEFORE}" + 1)) | \
            grep -E "$warn_pattern") || true
        if [ -n "$new_warns" ]; then
            local cnt
            cnt=$(echo "$new_warns" | wc -l)
            echo "  WARN: $cnt new kernel warning(s):"
            echo "$new_warns" | tail -5
        fi
    fi
    DMESG_WARN_SEEN=$cur_lines
    return 0
}

print_periodic_stats() {
    local elapsed="$1"

    # BQL stats and watchdog counter
    WD_CNT=$(cat /sys/class/net/${VETH_A}/queues/tx-${MQ_TXQ}/tx_timeout \
        2>/dev/null) || WD_CNT="?"
    if [ -n "$BQL_DIR" ] && [ -d "$BQL_DIR" ]; then
        INFLIGHT=$(cat "$BQL_DIR/inflight" 2>/dev/null || echo "?")
        LIMIT=$(cat "$BQL_DIR/limit" 2>/dev/null || echo "?")
        echo "  [${elapsed}s] BQL inflight=${INFLIGHT} limit=${LIMIT}" \
            "watchdog=${WD_CNT}"
    else
        echo "  [${elapsed}s] watchdog=${WD_CNT} (no BQL sysfs)"
    fi

    # Qdisc stats
    JQ_FMT='"qdisc \(.kind) pkts=\(.packets) drops=\(.drops)'
    JQ_FMT+=' requeues=\(.requeues) backlog=\(.backlog)'
    JQ_FMT+=' qlen=\(.qlen) overlimits=\(.overlimits)"'
    CUR_QPKTS=$(tc -j -s qdisc show dev "$VETH_A" root 2>/dev/null |
        jq -r '.[0].packets // 0' 2>/dev/null) || CUR_QPKTS=0
    QSTATS=$(tc -j -s qdisc show dev "$VETH_A" root 2>/dev/null |
        jq -r ".[0] | $JQ_FMT" 2>/dev/null) &&
        echo "  [${elapsed}s] $QSTATS" || true

    # Consumer PPS and per-packet processing time
    if [ "$PREV_QPKTS" -gt 0 ] 2>/dev/null; then
        DELTA=$((CUR_QPKTS - PREV_QPKTS))
        PPS=$((DELTA / INTERVAL))
        if [ "$PPS" -gt 0 ]; then
            PKT_MS=$(awk "BEGIN {printf \"%.3f\", 1000.0/$PPS}")
            NAPI_MS=$(awk "BEGIN {printf \"%.1f\", 64000.0/$PPS}")
            echo "  [${elapsed}s] consumer: ${PPS} pps" \
                "(~${PKT_MS}ms/pkt, NAPI-64 cycle ~${NAPI_MS}ms)"
        fi
    fi
    PREV_QPKTS=$CUR_QPKTS

    # softnet_stat: per-CPU tracking to detect same-CPU vs multi-CPU NAPI
    # /proc/net/softnet_stat columns: processed, dropped, time_squeeze (hex, per-CPU)
    local cpu=0 total_proc=0 total_sq=0 active_cpus=""
    while read -r line; do
        # shellcheck disable=SC2086  # word splitting on $line is intentional
        set -- $line
        local cur_p=$((0x${1})) cur_sq=$((0x${3}))
        if [ -f "$RESULTSDIR/softnet_cpu${cpu}" ]; then
            read -r prev_p prev_sq < "$RESULTSDIR/softnet_cpu${cpu}"
            local dp=$((cur_p - prev_p)) dsq=$((cur_sq - prev_sq))
            total_proc=$((total_proc + dp))
            total_sq=$((total_sq + dsq))
            [ "$dp" -gt 0 ] && active_cpus="${active_cpus} cpu${cpu}(+${dp})"
        fi
        echo "$cur_p $cur_sq" > "$RESULTSDIR/softnet_cpu${cpu}"
        cpu=$((cpu + 1))
    done < /proc/net/softnet_stat
    local n_active
    n_active=$(echo "$active_cpus" | wc -w)
    local cpu_mode="single-CPU"
    [ "$n_active" -gt 1 ] && cpu_mode="multi-CPU(${n_active})"
    if [ "$total_sq" -gt 0 ] && [ "$INTERVAL" -gt 0 ]; then
        echo "  [${elapsed}s] softnet: processed=${total_proc}" \
            "time_squeeze=${total_sq} (${total_sq}/${INTERVAL}s)" \
            "${cpu_mode}:${active_cpus}"
    else
        echo "  [${elapsed}s] softnet: processed=${total_proc}" \
            "time_squeeze=${total_sq}" \
            "${cpu_mode}:${active_cpus}"
    fi

    # napi_poll histogram (from bpftrace, if running)
    if [ -n "$BPFTRACE_PID" ] && [ -f "$RESULTSDIR"/napi_poll.log ]; then
        local napi_line
        napi_line=$(grep '^napi_poll:' "$RESULTSDIR"/napi_poll.log | tail -1)
        [ -n "$napi_line" ] && echo "  [${elapsed}s] $napi_line"
    fi

    # BQL inflight histogram (from bpftrace, if running)
    if [ -n "$BPFTRACE2_PID" ] && [ -f "$RESULTSDIR"/bql_inflight.log ]; then
        local bql_line
        bql_line=$(grep '^bql_inflight:' "$RESULTSDIR"/bql_inflight.log | tail -1)
        [ -n "$bql_line" ] && echo "  [${elapsed}s] $bql_line"
    fi

    # BQL completion interval (from bpftrace, if running)
    if [ -n "$BPFTRACE3_PID" ] && [ -f "$RESULTSDIR"/bql_interval.log ]; then
        local bql_int_line
        bql_int_line=$(grep '^bql_interval:' "$RESULTSDIR"/bql_interval.log | tail -1)
        [ -n "$bql_int_line" ] && echo "  [${elapsed}s] $bql_int_line"
    fi

    # Ping RTT
    PING_RTT=$(tail -1 "$RESULTSDIR"/ping.log 2>/dev/null | grep -oP 'time=\K[0-9.]+') &&
        echo "  [${elapsed}s] ping RTT=${PING_RTT}ms" || true
}

monitor_loop() {
    ELAPSED=0
    INTERVAL=5
    PREV_QPKTS=0
    # Seed per-CPU softnet baselines
    local cpu=0
    while read -r line; do
        # shellcheck disable=SC2086  # word splitting on $line is intentional
        set -- $line
        echo "$((0x${1})) $((0x${3}))" > "$RESULTSDIR/softnet_cpu${cpu}"
        cpu=$((cpu + 1))
    done < /proc/net/softnet_stat
    # Verify iptables rules are being hit once traffic is flowing
    verify_iptables_hit
    while kill -0 "$FLOOD_PID" 2>/dev/null; do
        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))

        if ! check_dmesg_bug; then
            RET=$ksft_fail
            retmsg="BUG_ON triggered in dql_completed at ${ELAPSED}s"
            log_test "veth_bql"
            exit "$EXIT_STATUS"
        fi

        print_periodic_stats "$ELAPSED"
    done
    wait "$FLOOD_PID" || true
    FLOOD_PID=""
}

# Verify traffic is flowing by checking device tx_packets counter.
# Works for both qdisc and noqueue modes.
verify_traffic_flowing() {
    local label="$1"
    local prev_tx cur_tx

    # Skip check if flood producer already exited (not a stall)
    if [ -n "$FLOOD_PID" ] && ! kill -0 "$FLOOD_PID" 2>/dev/null; then
        log_info "$label flood producer exited (duration reached)"
        return 0
    fi

    prev_tx=$(cat /sys/class/net/${VETH_A}/statistics/tx_packets \
        2>/dev/null) || prev_tx=0
    sleep 0.5
    cur_tx=$(cat /sys/class/net/${VETH_A}/statistics/tx_packets \
        2>/dev/null) || cur_tx=0
    if [ "$cur_tx" -gt "$prev_tx" ]; then
        log_info "$label traffic flowing (tx: $prev_tx -> $cur_tx)"
        return 0
    fi
    log_info "$label traffic STALLED (tx: $prev_tx -> $cur_tx)"
    return 1
}

collect_results() {
    local test_name="${1:-veth_bql}"

    # Ping summary
    wait "$PING_PID" 2>/dev/null || true
    PING_PID=""
    if [ -f "$RESULTSDIR"/ping.log ]; then
        PING_LOSS=$(grep -o '[0-9.]*% packet loss' "$RESULTSDIR"/ping.log) &&
            log_info "Ping loss: $PING_LOSS"
        PING_STATS=$(grep -oP 'time=\K[0-9.]+' "$RESULTSDIR"/ping.log | \
            sort -n | awk '{a[NR]=$1; sum+=$1}
                 END {if(NR>0) {idx=int(NR*0.99); if(idx<1) idx=1;
                      printf "n=%d avg=%.3f p99=%.3f ms\n", NR, sum/NR, a[idx]}}')
        [ -n "$PING_STATS" ] && log_info "Ping RTT: $PING_STATS"
    fi

    # Watchdog summary
    WD_FINAL=$(cat /sys/class/net/${VETH_A}/queues/tx-${MQ_TXQ}/tx_timeout \
        2>/dev/null) || WD_FINAL=0
    if [ "$WD_FINAL" -gt 0 ] 2>/dev/null; then
        log_info "Watchdog fired ${WD_FINAL} time(s)"
        dmesg | tail -n +$((DMESG_BEFORE + 1)) | \
            grep -E 'NETDEV WATCHDOG|veth backpressure' || true
    fi

    # Stop bpftrace so END block (histograms) flushes to log files.
    if [ -n "$BPFTRACE_PID" ]; then
        kill "$BPFTRACE_PID" 2>/dev/null
        wait "$BPFTRACE_PID" 2>/dev/null
        BPFTRACE_PID=""
    fi
    if [ -n "$BPFTRACE2_PID" ]; then
        kill "$BPFTRACE2_PID" 2>/dev/null
        wait "$BPFTRACE2_PID" 2>/dev/null
        BPFTRACE2_PID=""
    fi
    if [ -n "$BPFTRACE3_PID" ]; then
        kill "$BPFTRACE3_PID" 2>/dev/null
        wait "$BPFTRACE3_PID" 2>/dev/null
        BPFTRACE3_PID=""
    fi

    # Print bpftrace histograms if verbose
    if [ "$PRINT_HIST" -eq 1 ]; then
        for logfile in "$RESULTSDIR"/napi_poll.log "$RESULTSDIR"/bql_inflight.log "$RESULTSDIR"/bql_interval.log; do
            if [ -f "$logfile" ]; then
                echo ""
                echo "=== $(basename "$logfile") ==="
                cat "$logfile"
            fi
        done
    fi

    # Goodput: actual packets delivered to the peer (rx_packets delta).
    # This is the real throughput -- pktgen's count includes packets that
    # a dropping qdisc (fq_codel) enqueued then dropped on dequeue.
    local rx_after
    rx_after=$(ip netns exec "$NS" cat /sys/class/net/"$VETH_B"/statistics/rx_packets 2>/dev/null) || rx_after=0
    local rx_delta=$((rx_after - RX_BEFORE))
    local goodput_pps=$((rx_delta / (DURATION > 0 ? DURATION : 1)))
    echo "$goodput_pps" > "$RESULTSDIR/goodput_pps"
    log_info "Goodput: ${goodput_pps} pps ($rx_delta pkts in ${DURATION}s)"

    # Qdisc drop count
    local qdisc_drops
    qdisc_drops=$(tc -j -s qdisc show dev "$VETH_A" root 2>/dev/null | \
        jq -r '.[0].drops // 0' 2>/dev/null) || qdisc_drops=0
    echo "$qdisc_drops" > "$RESULTSDIR/qdisc_drops"
    log_info "Qdisc drops: $qdisc_drops"

    # pktgen result summary
    if [ "$USE_PKTGEN" -eq 1 ]; then
        local last_thread=$((PKTGEN_THREADS - 1))
        for ((thread = 0; thread <= last_thread; thread++)); do
            local pgdev_file="/proc/net/pktgen/${VETH_A}@${thread}"
            if [ -f "$pgdev_file" ]; then
                log_info "pktgen results (thread $thread):"
                cat "$pgdev_file"
                cat "$pgdev_file" >> "$RESULTSDIR/pktgen.log" 2>/dev/null || true
            fi
        done
    fi

    # Detect traffic stall: if goodput is near zero while flood was running,
    # the TX queue is likely stuck (veth txq-wake bug).  Skip this check in
    # ping-only mode where no flood traffic is expected.
    #
    # Characteristic pattern of the stuck-queue bug:
    #   - goodput near zero (queue stopped, no packets delivered)
    #   - requeues = 1 (queue stopped once, never restarted)
    #   - drops growing (new packets enqueued but dropped at qdisc limit)
    #   - pkts constant (no new packets dequeued/transmitted)
    if [ "$PING_ONLY" -eq 0 ] && [ "$goodput_pps" -lt 100 ]; then
        local requeues
        requeues=$(tc -j -s qdisc show dev "$VETH_A" root 2>/dev/null | \
            jq -r '.[0].requeues // 0' 2>/dev/null) || requeues="?"
        RET=$ksft_fail
        retmsg="traffic stall: goodput=${goodput_pps} pps,"
        retmsg+=" drops=${qdisc_drops}, requeues=${requeues} (TX queue stuck?)"
        log_info "FAIL: $retmsg"
    fi

    # Final dmesg check -- only upgrade to fail, never override existing fail
    if ! check_dmesg_bug; then
        RET=$ksft_fail
        retmsg="BUG_ON triggered in dql_completed"
    fi
    log_test "$test_name"
    exit "$EXIT_STATUS"
}

# --- Test modes ---

test_bql_stress() {
    RET=$ksft_pass
    setup_veth
    install_qdisc "$QDISC" "$QDISC_OPTS"
    setup_iptables
    log_info "kernel: $(uname -r)"
    check_bql_sysfs
    if [ "$USE_PKTGEN" -eq 1 ]; then
        start_traffic_pktgen
    else
        start_traffic
    fi
    monitor_loop
    collect_results "veth_bql"
}

# Test qdisc replacement under active traffic.  Cycles through several
# qdiscs including a transition to noqueue (tc qdisc del) to verify
# that stale BQL state (STACK_XOFF) is properly reset during qdisc
# transitions.
test_qdisc_replace() {
    local qdiscs=("sfq" "pfifo" "fq_codel")
    local step=2
    local elapsed=0
    local idx

    RET=$ksft_pass
    setup_veth
    install_qdisc "$QDISC" "$QDISC_OPTS"
    setup_iptables
    log_info "kernel: $(uname -r)"
    check_bql_sysfs
    start_traffic

    while [ "$elapsed" -lt "$DURATION" ] && kill -0 "$FLOOD_PID" 2>/dev/null; do
        sleep "$step"
        elapsed=$((elapsed + step))

        if ! check_dmesg_bug; then
            RET=$ksft_fail
            retmsg="BUG_ON during qdisc replacement at ${elapsed}s"
            break
        fi

        # Cycle: sfq -> pfifo -> fq_codel -> noqueue -> sfq -> ...
        idx=$(( (elapsed / step - 1) % (${#qdiscs[@]} + 1) ))
        if [ "$idx" -eq "${#qdiscs[@]}" ]; then
            remove_qdisc
        else
            install_qdisc "${qdiscs[$idx]}"
        fi

        # Print BQL and qdisc stats after each replacement
        if [ -n "$BQL_DIR" ] && [ -d "$BQL_DIR" ]; then
            local inflight limit limit_min limit_max holding
            inflight=$(cat "$BQL_DIR/inflight" 2>/dev/null || echo "?")
            limit=$(cat "$BQL_DIR/limit" 2>/dev/null || echo "?")
            limit_min=$(cat "$BQL_DIR/limit_min" 2>/dev/null || echo "?")
            limit_max=$(cat "$BQL_DIR/limit_max" 2>/dev/null || echo "?")
            holding=$(cat "$BQL_DIR/holding_time" 2>/dev/null || echo "?")
            echo "  [${elapsed}s] BQL inflight=${inflight} limit=${limit}" \
                "limit_min=${limit_min} limit_max=${limit_max}" \
                "holding=${holding}"
        fi
        local cur_qdisc
        cur_qdisc=$(tc qdisc show dev "$VETH_A" root 2>/dev/null | \
            awk '{print $2}') || cur_qdisc="none"
        local txq_state
        txq_state=$(cat /sys/class/net/${VETH_A}/queues/tx-${MQ_TXQ}/tx_timeout \
            2>/dev/null) || txq_state="?"
        echo "  [${elapsed}s] qdisc=${cur_qdisc} watchdog=${txq_state}"

        if ! verify_traffic_flowing "[${elapsed}s]"; then
            RET=$ksft_fail
            retmsg="Traffic stalled after qdisc replacement at ${elapsed}s"
            break
        fi
    done

    stop_traffic
    collect_results "veth_bql_qdisc_replace"
}

# Baseline ping RTT measurement -- no flood traffic.
# Sets up the same veth pair and iptables rules as the stress test,
# then runs ping for DURATION seconds to measure the baseline cost
# of packet processing through the iptables ruleset.
test_ping() {
    RET=$ksft_pass
    setup_veth
    install_qdisc "$QDISC" "$QDISC_OPTS"
    setup_iptables
    log_info "kernel: $(uname -r)"
    check_bql_sysfs

    DMESG_BEFORE=$(dmesg | wc -l)

    log_info "Starting baseline ping to $IP_B (5/s) for ${DURATION}s"
    ping -i 0.2 -w "$DURATION" "$IP_B" > "$RESULTSDIR"/ping.log 2>&1 &
    PING_PID=$!

    wait "$PING_PID" 2>/dev/null || true
    PING_PID=""

    # Write a zero goodput so extract_pps returns 0 (no flood traffic)
    echo "0" > "$RESULTSDIR/goodput_pps"

    if [ -f "$RESULTSDIR"/ping.log ]; then
        PING_LOSS=$(grep -o '[0-9.]*% packet loss' "$RESULTSDIR"/ping.log) &&
            log_info "Ping loss: $PING_LOSS"
        PING_STATS=$(grep -oP 'time=\K[0-9.]+' "$RESULTSDIR"/ping.log | \
            sort -n | awk '{a[NR]=$1; sum+=$1}
                 END {if(NR>0) {idx=int(NR*0.99); if(idx<1) idx=1;
                      printf "n=%d avg=%.3f p99=%.3f ms\n", NR, sum/NR, a[idx]}}')
        [ -n "$PING_STATS" ] && log_info "Ping RTT: $PING_STATS"
    fi

    if ! check_dmesg_bug; then
        RET=$ksft_fail
        retmsg="BUG_ON triggered during ping test"
    fi
    log_test "veth_bql_ping"
    exit "$EXIT_STATUS"
}

# --- Main ---
if [ "$PING_ONLY" -eq 1 ]; then
    test_ping
elif [ "$QDISC_REPLACE" -eq 1 ]; then
    test_qdisc_replace
else
    test_bql_stress
fi
