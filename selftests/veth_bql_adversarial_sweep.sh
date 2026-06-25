#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Parameter sweep for veth_bql_adversarial.sh.
# Sweeps over tx-usecs (BQL coalescing window) and nrules (expensive-chain
# length), running each (tx-usecs, nrules) combination N times and collecting
# the baseline-vs-adversarial ping RTT and BQL limit, plus the inflation/spike
# ratios that quantify how much the cheap-traffic burst hurts.
#
# veth_bql_adversarial.sh exports its raw per-phase samples (via SAMPLES_DIR):
#   rtt.<phase>  -- every ping RTT sample (ms)
#   lim.<phase>  -- every BQL limit sample (pkts)
# This sweep POOLS those raw samples across all runs of a combo and reports
# stable high percentiles (p99/p99.9) over the pool, rather than averaging each
# run's max -- mean-of-per-run-max is a single-packet outlier estimator and swings
# wildly.  The BQL limit (the direct DQL state) is the cleanest signal; it is
# immune to the fq_codel flow-count confound and reported as p50 + max.
#
# Usage:
#   ./veth_bql_adversarial_sweep.sh [OPTIONS] -- [veth_bql_adversarial.sh args...]
#
# Example:
#   ./veth_bql_adversarial_sweep.sh --runs 5 --tx-usecs-list "100 500 1000 2000" \
#       --nrules-list "1000 2500 5000" -- --duration 20 --cheap-size 64
#
# Must run as root (the adversarial test creates netns/veth, loads iptables).

SCRIPTDIR="$(cd "$(dirname -- "$0")" && pwd)"
ADV="$SCRIPTDIR/veth_bql_adversarial.sh"

# Defaults
RUNS=5
TX_USECS_LIST="10 50 100 500 1000"
NRULES_LIST="1 10 100 1000 10000"
OUTDIR=""
XDP_DROP=0           # 1 = pass --xdp-drop to the adversarial test (XDP cheap path)

usage() {
    echo "Usage: $0 [OPTIONS] -- [veth_bql_adversarial.sh options...]"
    echo ""
    echo "Options:"
    echo "  --runs N              iterations per (tx-usecs, nrules) combo (default: $RUNS)"
    echo "  --tx-usecs-list LIST  space-separated tx-usecs values in us (default: $TX_USECS_LIST)"
    echo "  --nrules-list LIST    space-separated nrules values (default: $NRULES_LIST)"
    echo "  --outdir DIR          output directory for CSV results (default: auto)"
    echo "  --xdp-drop            use the XDP cheap path (passes --xdp-drop through;"
    echo "                        defeats BQL at tx-usecs=100; needs: make xdp)"
    echo ""
    echo "Example:"
    echo "  $0 --runs 5 --tx-usecs-list '100 500 1000 2000' \\"
    echo "     --nrules-list '1000 2500 5000' -- --duration 20 --cheap-size 64"
    exit 1
}

# Parse our options (before the --)
while [ $# -gt 0 ]; do
    case "$1" in
    --runs)           RUNS="$2"; shift 2 ;;
    --tx-usecs-list)  TX_USECS_LIST="$2"; shift 2 ;;
    --nrules-list)    NRULES_LIST="$2"; shift 2 ;;
    --outdir)         OUTDIR="$2"; shift 2 ;;
    --xdp-drop)       XDP_DROP=1; shift ;;
    --help|-h)        usage ;;
    --)               shift; break ;;
    *)                break ;;
    esac
done

TEST_ARGS=("$@")
# Forward --xdp-drop to every adversarial invocation.
[ "$XDP_DROP" -eq 1 ] && TEST_ARGS+=("--xdp-drop")

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }
[ -f "$ADV" ] || { echo "not found: $ADV"; exit 1; }

# Setup output directory
if [ -z "$OUTDIR" ]; then
    REPO_ROOT="$(dirname "$SCRIPTDIR")"
    OUTDIR="$REPO_ROOT/results/adversarial-sweep/$(date +%Y-%m-%dT%H-%M-%S)"
fi
mkdir -p "$OUTDIR"

CSV="$OUTDIR/sweep.csv"

# Nearest-rank percentile over a file of numbers (one per line). Empty -> 0.
# _pctile <file> <pct>   (pct may be fractional, e.g. 99.9)
# Uses the textbook nearest-rank rank = ceil(p/100 * N) (so p100 -> max, and the
# tail rounds up).  NOTE: at small N, p99/p99.9 saturate to the max -- only the
# pooled high percentiles (large N) are meaningful; lean on p99, treat p99.9 as
# a rough worst-case.
_pctile() {
    sort -n "$1" 2>/dev/null | awk -v p="$2" '
        {a[NR]=$1}
        END{
            if (NR==0) { print 0; exit }
            t = p/100*NR; idx = int(t); if (idx < t) idx++;   # ceil(p/100 * N)
            if(idx<1) idx=1; if(idx>NR) idx=NR;
            print a[idx]
        }'
}

# Run veth_bql_adversarial.sh $RUNS times, POOLING raw samples across runs.
# Prints pooled percentiles:
#   b_rtt_p50 b_rtt_p99 b_rtt_p999 b_lim_p50 b_lim_max
#   a_rtt_p50 a_rtt_p99 a_rtt_p999 a_lim_p50 a_lim_max
run_combo() {  # $1 label, rest: extra args to adversarial
    local label="$1"; shift
    local -a extra=("$@")
    local pool="$OUTDIR/pool.$label"
    rm -rf "$pool"; mkdir -p "$pool"

    # Column header for the live per-run lines below.  Must match the per-phase
    # layout the adversarial script prints (%-12s %10s %10s %10s %10s) and the
    # "    " prefix + "  |  " separator used when echoing each run, so it aligns.
    local hdr
    hdr=$(printf "%-12s %10s %10s %10s %10s" "phase" "rtt_avg" "rtt_p99" "rtt_max" "limit")
    echo "    $hdr  |  $hdr" >&2

    for ((i = 1; i <= RUNS; i++)); do
        echo "  [$label] run $i/$RUNS ..." >&2
        local rundir log
        rundir=$(mktemp -d "/tmp/veth_bql_adv.${label}.XXXXXX")
        log="$rundir/stdout.log"
        SAMPLES_DIR="$rundir" bash "$ADV" "${TEST_ARGS[@]}" "${extra[@]}" > "$log" 2>&1

        # Pool this run's raw samples into the combo-level pool.
        cat "$rundir/rtt.baseline"    2>/dev/null >> "$pool/rtt.baseline"
        cat "$rundir/rtt.adversarial" 2>/dev/null >> "$pool/rtt.adversarial"
        cat "$rundir/lim.baseline"    2>/dev/null >> "$pool/lim.baseline"
        cat "$rundir/lim.adversarial" 2>/dev/null >> "$pool/lim.adversarial"

        # Echo this run's own summary lines for the live log.
        echo "    $(grep -m1 '^baseline ' "$log")  |  $(grep -m1 '^adversarial ' "$log")" >&2
        cp "$log" "$OUTDIR/${label}.run${i}.log" 2>/dev/null
        rm -rf "$rundir"
    done

    echo "$(_pctile "$pool/rtt.baseline" 50) $(_pctile "$pool/rtt.baseline" 99) \
$(_pctile "$pool/rtt.baseline" 99.9) $(_pctile "$pool/lim.baseline" 50) $(_pctile "$pool/lim.baseline" 100) \
$(_pctile "$pool/rtt.adversarial" 50) $(_pctile "$pool/rtt.adversarial" 99) \
$(_pctile "$pool/rtt.adversarial" 99.9) $(_pctile "$pool/lim.adversarial" 50) $(_pctile "$pool/lim.adversarial" 100)"
}

# --- Main ---

echo "=== veth BQL adversarial parameter sweep ==="
echo "Runs per combo:  $RUNS"
echo "tx-usecs values: $TX_USECS_LIST"
echo "nrules values:   $NRULES_LIST"
echo "Test args:       ${TEST_ARGS[*]}"
echo "Output:          $OUTDIR"
echo ""

CMDLINE="$0 $*"
echo "$CMDLINE" > "$OUTDIR/cmdline.sh"

echo "# $CMDLINE" > "$CSV"
echo "tx_usecs,nrules,b_rtt_p50,b_rtt_p99,b_rtt_p999,b_lim_p50,b_lim_max,a_rtt_p50,a_rtt_p99,a_rtt_p999,a_lim_p50,a_lim_max,lim_max_ratio,rtt_p99_ratio,rtt_p999_ratio" >> "$CSV"

read -ra _tu_arr <<< "$TX_USECS_LIST"
read -ra _nr_arr <<< "$NRULES_LIST"
TOTAL=$(( ${#_tu_arr[@]} * ${#_nr_arr[@]} ))
CURRENT=0

declare -a R_TX R_NR R_BLIM R_ALIM R_BP99 R_AP99 R_LRAT R_PRAT

for tx_usecs in $TX_USECS_LIST; do
    for nrules in $NRULES_LIST; do
        CURRENT=$((CURRENT + 1))
        label="tu${tx_usecs}_nr${nrules}"
        echo "--- [$CURRENT/$TOTAL] tx-usecs=$tx_usecs nrules=$nrules ---"

        read -r bp50 bp99 bp999 blp50 blmax ap50 ap99 ap999 alp50 almax <<< \
            "$(run_combo "$label" --tx-usecs "$tx_usecs" --nrules "$nrules")"

        # Ratios (adversarial / baseline) over POOLED percentiles; 0 if base is 0.
        read -r lrat prat p9rat <<< "$(awk -v bl="$blmax" -v al="$almax" \
            -v bp="$bp99" -v ap="$ap99" -v bq="$bp999" -v aq="$ap999" 'BEGIN{
                printf "%.2f %.2f %.2f", (bl?al/bl:0), (bp?ap/bp:0), (bq?aq/bq:0)
            }')"

        echo "$tx_usecs,$nrules,$bp50,$bp99,$bp999,$blp50,$blmax,$ap50,$ap99,$ap999,$alp50,$almax,$lrat,$prat,$p9rat" >> "$CSV"

        R_TX+=("$tx_usecs"); R_NR+=("$nrules")
        R_BLIM+=("$blmax"); R_ALIM+=("$almax")
        R_BP99+=("$bp99"); R_AP99+=("$ap99")
        R_LRAT+=("$lrat"); R_PRAT+=("$prat")

        # p99.9 is in the CSV but not shown here: at this pooled N it degenerates
        # to the max (single worst packet), so it is not a meaningful percentile.
        echo "  => limit_max ${blmax}->${almax} (x${lrat})  rtt_p99 ${bp99}->${ap99}ms (x${prat})"
        echo ""
    done
done

# --- Summary table ---
echo "================================================================"
echo "Adversarial sweep results (percentiles POOLED over $RUNS runs)"
echo "================================================================"
printf "%-10s %-8s %10s %10s %12s %12s %8s %8s\n" \
    "tx-usecs" "nrules" "lim_base" "lim_adv" "p99_base" "p99_adv" "lim_x" "p99_x"
printf "%-10s %-8s %10s %10s %12s %12s %8s %8s\n" \
    "--------" "------" "--------" "-------" "--------" "-------" "-----" "-----"
for ((i = 0; i < ${#R_TX[@]}; i++)); do
    printf "%-10s %-8s %10s %10s %12s %12s %8s %8s\n" \
        "${R_TX[$i]}" "${R_NR[$i]}" "${R_BLIM[$i]}" "${R_ALIM[$i]}" \
        "${R_BP99[$i]}" "${R_AP99[$i]}" "${R_LRAT[$i]}" "${R_PRAT[$i]}"
done
echo "================================================================"
echo "(lim = BQL limit pkts [max]; p99 = pooled ping RTT ms; _x = adversarial/baseline)"
echo "(p99.9 is in the CSV only -- at this pooled N it collapses to the max)"
echo "(limit is the clean signal -- flow-count-confound-immune; RTT pooled for stability)"
echo ""
echo "CSV saved to: $CSV"
echo "Full logs in: $OUTDIR"
