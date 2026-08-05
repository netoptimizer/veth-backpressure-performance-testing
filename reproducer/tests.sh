#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/venv/bin/activate"

# Use sudo for privileged commands when not running as root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo env PATH=$PATH"

# Defaults
TIME=60

# Parse command line options
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) TIME="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; echo "Usage: $0 [--duration SEC]" >&2; exit 1 ;;
  esac
done

DEV=server-link
NS=router
# Warmup: exclude first N seconds from ping stats (elephant ramp-up)
WARMUP=10

SERVER_IP=192.168.20.2
CLIENT_IP=198.18.0.2

# --- Pre-flight checks ---
# Verify namespaces exist (setup.sh must be run first)
if ! $SUDO ip netns exec server true 2>/dev/null; then
  echo "ERROR: 'server' netns not found. Run ./reproducer/setup.sh first." >&2
  exit 1
fi

# bbperf server check is done later — auto-started if not running

# Results directory: results/reproducer/<timestamp>/ with 'latest' symlink
TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
RESULTS_DIR="${REPO_ROOT}/results/reproducer/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"
ln -sfn "${TIMESTAMP}" "${REPO_ROOT}/results/reproducer/latest"
echo "Results dir: ${RESULTS_DIR}"

# Tee all output to a log file in the results dir
exec > >(tee "${RESULTS_DIR}/tests.log") 2>&1

# Record command line for easy re-run
printf '%q ' "$0" "$@" > "${RESULTS_DIR}/cmdline.txt"
echo >> "${RESULTS_DIR}/cmdline.txt"

# Record system info for reproducibility
{
  echo "=== Kernel ==="
  uname -r
  echo ""
  echo "=== Kernel version ==="
  cat /proc/version
  echo ""
  echo "=== CPU ==="
  lscpu | grep -E '^(Model name|Architecture|CPU\(s\)|Thread|Core|Socket|CPU max MHz|CPU min MHz)'
  echo ""
  echo "=== Memory ==="
  free -h | head -2
  echo ""
  echo "=== bbperf ==="
  pip show bbperf 2>/dev/null | grep -E '^(Name|Version):' || echo "bbperf version unknown"
  echo ""
  echo "=== veth BQL (${NS} netns, dev ${DEV}) ==="
  bql_dir="/sys/devices/virtual/net/${DEV}/queues"
  if $SUDO ip netns exec ${NS} test -d "${bql_dir}/tx-0/byte_queue_limits" 2>/dev/null; then
    $SUDO ip netns exec ${NS} bash -c "
      for q in ${bql_dir}/tx-*/byte_queue_limits; do
        queue=\$(basename \$(dirname \$q))
        max=\$(cat \$q/limit_max)
        cur=\$(cat \$q/limit)
        echo \"${DEV}/\${queue}: limit_max=\${max} limit=\${cur}\"
      done
    "
    echo "veth BQL: SUPPORTED"
  else
    echo "veth BQL: NOT SUPPORTED (no byte_queue_limits in sysfs)"
    echo "Kernel $(uname -r) does not have veth BQL backpressure."
  fi
  echo ""
  echo "=== Test params ==="
  echo "TIME=${TIME} WARMUP=${WARMUP}"
  echo "date: $(date -Iseconds)"
} > "${RESULTS_DIR}/sysinfo.txt" 2>&1

# Start bbperf server if not already running, and clean up on exit
PING_PID=""
SERVER_PID=""
OWN_SERVER=false

if ! $SUDO ip netns exec server ss -tlnp 2>/dev/null | grep -q ':5301'; then
  echo "Starting bbperf server in background..."
  $SUDO ip netns exec server bbperf -s -B $SERVER_IP \
    > "${RESULTS_DIR}/server.log" 2>&1 &
  SERVER_PID=$!
  OWN_SERVER=true
  # Give server time to bind
  sleep 0.5
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: bbperf server failed to start. See ${RESULTS_DIR}/server.log" >&2
    exit 1
  fi
  echo "bbperf server started (pid $SERVER_PID, log: ${RESULTS_DIR}/server.log)"
fi

cleanup() {
  if [ -n "$PING_PID" ]; then
    kill "$PING_PID" 2>/dev/null || true
    wait "$PING_PID" 2>/dev/null || true
    PING_PID=""
  fi
  if [ "$OWN_SERVER" = true ] && [ -n "$SERVER_PID" ]; then
    echo "Stopping bbperf server (pid $SERVER_PID)..."
    $SUDO kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}
trap cleanup EXIT

# Accumulate per-test results for summary table
declare -a TEST_NAMES=()
declare -a PING_AVGS=()
declare -a PING_P99S=()
declare -a PING_MAXS=()
declare -a PING_LOSSES=()
declare -a BBPERF_AVGS=()
declare -a BBPERF_P99S=()
declare -a TEST_STATUSES=()

parse_ping_stats() {
  local logfile="$1"
  local warmup="$2"
  python3 -c "
import re, sys
warmup = float('${warmup}')
lines = open('${logfile}').readlines()
all_rtts = []
for line in lines:
    m = re.match(r'\[(\d+\.\d+)\].*time=([0-9.]+)\s*ms', line)
    if m:
        all_rtts.append((float(m.group(1)), float(m.group(2))))
if not all_rtts:
    print('- - - - -')
    sys.exit(0)
# Compute loss from summary line (handle floats like '2.04082% packet loss')
loss = 0.0
for line in lines:
    m = re.search(r'([\d.]+)%\s*packet loss', line)
    if m:
        loss = float(m.group(1))
        break
t0 = all_rtts[0][0]
# Steady-state: exclude warmup period
steady = [rtt for ts, rtt in all_rtts if ts - t0 >= warmup]
if not steady:
    steady = [rtt for _, rtt in all_rtts]
steady.sort()
n = len(steady)
p99_idx = min(int(n * 0.99), n - 1)
avg = sum(steady) / n
print(f'{avg:.1f} {steady[p99_idx]:.1f} {steady[-1]:.1f} {loss:.1f} {n}')
"
}

parse_bbperf_stats() {
  local jsonfile="$1"
  python3 -c "
import json, sys
with open('${jsonfile}') as f:
    d = json.load(f)
valid = [e for e in d['entries'] if e.get('is_sample_valid')]
if valid:
    rtts = sorted(e['loaded_rtt_ms'] for e in valid)
    n = len(rtts)
    p99_idx = min(int(n * 0.99), n - 1)
    avg = sum(rtts) / n
    print(f'{avg:.1f} {rtts[p99_idx]:.1f}')
else:
    print('- -')
"
}

run_test() {
  output=$1
  echo -e "\n=== $output === (runs for $TIME sec)"

  # Start ping with per-packet timestamps (-D) in background.
  # bbperf has ~8s UDP calibration before its test starts, so run ping
  # longer than bbperf -t to cover both calibration and test phases.
  local ping_deadline=$((TIME + 20))
  local ping_log="${RESULTS_DIR}/ping-${output}.log"
  ($SUDO ip netns exec client ping -D -w $ping_deadline -i 0.1 $SERVER_IP \
     > "$ping_log" 2>&1)&
  PING_PID=$!

  # Run bbperf elephant flow; capture exit code instead of aborting on failure.
  # bbperf can time out when a TX queue is permanently stuck (the veth txq-wake
  # bug causes its TCP control connection to hang if it lands on a stopped queue).
  local bbperf_rc=0
  local bbperf_log="${RESULTS_DIR}/bbperf-${output}.log"
  $SUDO ip netns exec client bbperf -t $TIME -u -c $SERVER_IP -B $CLIENT_IP \
            -g --graph-file "${RESULTS_DIR}/bbperf-graph-${output}.png" \
            -J "${RESULTS_DIR}/${output}.json" \
    2>"$bbperf_log" || bbperf_rc=$?

  if [ $bbperf_rc -ne 0 ]; then
    echo "*** bbperf FAILED (exit code $bbperf_rc) -- possible stuck txq ***"
    echo "    (see $bbperf_log for details)"
  fi

  # Stop ping (it has a longer deadline to cover bbperf calibration)
  $SUDO kill -INT "$PING_PID" 2>/dev/null || true
  wait "$PING_PID" 2>/dev/null || true
  PING_PID=""

  # Print ping summary from log
  echo "--- ping results (${output}) ---"
  tail -3 "$ping_log" 2>/dev/null || echo "(no ping data)"

  # Qdisc output: Look for requeues
  $SUDO ip netns exec ${NS} tc -s qdisc ls dev ${DEV}
  # Interface stats: Look for TX dropped
  $SUDO ip -netns ${NS} -s link ls dev ${DEV}

  # Generate graphs (skip if bbperf failed -- JSON may be empty/corrupt)
  if [ $bbperf_rc -eq 0 ]; then
    # Generate combined graph with ping overlay
    "${SCRIPT_DIR}/plot_combined.sh" \
      "${RESULTS_DIR}/${output}.json" \
      "$ping_log" \
      "${RESULTS_DIR}/combined-${output}.png" \
      "${output} (elephant UDP + ping RTT)" || true

    # Generate bbperf-style multi-panel graph with ping overlay
    "${SCRIPT_DIR}/plot_multi.sh" \
      "${RESULTS_DIR}/${output}.json" \
      "$ping_log" \
      "${RESULTS_DIR}/multi-${output}.png" \
      "${output}" || true
  fi

  # Collect stats for summary table
  TEST_NAMES+=("$output")
  if [ $bbperf_rc -eq 0 ]; then
    TEST_STATUSES+=("OK")
  else
    TEST_STATUSES+=("FAIL")
  fi
  local pstats
  pstats=$(parse_ping_stats "$ping_log" "$WARMUP")
  PING_AVGS+=($(echo "$pstats" | awk '{print $1}'))
  PING_P99S+=($(echo "$pstats" | awk '{print $2}'))
  PING_MAXS+=($(echo "$pstats" | awk '{print $3}'))
  PING_LOSSES+=($(echo "$pstats" | awk '{print $4}'))
  local bstats
  if [ $bbperf_rc -eq 0 ]; then
    bstats=$(parse_bbperf_stats "${RESULTS_DIR}/${output}.json")
  else
    bstats="- -"
  fi
  BBPERF_AVGS+=($(echo "$bstats" | awk '{print $1}'))
  BBPERF_P99S+=($(echo "$bstats" | awk '{print $2}'))

  # Restart bbperf server if it died (needed for subsequent tests)
  if [ $bbperf_rc -ne 0 ] && [ "$OWN_SERVER" = true ]; then
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "Restarting bbperf server..."
      $SUDO ip netns exec server bbperf -s -B $SERVER_IP \
        > "${RESULTS_DIR}/server.log" 2>&1 &
      SERVER_PID=$!
      sleep 0.5
    fi
  fi
}

$SUDO ip netns exec ${NS} tc qdisc del dev ${DEV} root 2>/dev/null || true
run_test "no_qdisc"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root fq_codel
run_test "fq_codel"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root codel
run_test "codel"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root sfq
run_test "sfq"

# For MQ tests add some more queues to the veth device
# - this will make ping test results unreliable as a drop indicator
MQs=2
$SUDO ip netns exec client ethtool --set-channels to-router   rx $MQs tx $MQs
$SUDO ip netns exec router ethtool --set-channels client-link rx $MQs tx $MQs
$SUDO ip netns exec router ethtool --set-channels server-link rx $MQs tx $MQs
$SUDO ip netns exec server ethtool --set-channels in-router   rx $MQs tx $MQs

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root handle 1: mq
for sq in $($SUDO ip netns exec ${NS} tc -j qdisc show dev ${DEV} | jq -r .[].parent | grep -v null); do
  $SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} parent ${sq} fq_codel
done
run_test "mq_fq_codel_qdisc"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root handle 1: mq
for sq in $($SUDO ip netns exec ${NS} tc -j qdisc show dev ${DEV} | jq -r .[].parent | grep -v null); do
  $SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} parent ${sq} sfq
done
run_test "mq_sfq_qdisc"

# --- Summary table ---
# Print a single, consistently-formatted table to both stdout and summary.txt.
# Build each value with its unit suffix first, then use a single %Ns column
# width so headers and data align in monospace output.
print_summary() {
  printf "%-22s %6s %10s %10s %10s %10s  %12s %12s\n" \
         "qdisc" "status" "ping_avg" "ping_p99" "ping_max" "ping_loss" "bbperf_avg" "bbperf_p99"
  printf "%-22s %6s %10s %10s %10s %10s  %12s %12s\n" \
         "-----" "------" "--------" "--------" "--------" "---------" "----------" "----------"
  for i in "${!TEST_NAMES[@]}"; do
    printf "%-22s %6s %10s %10s %10s %10s  %12s %12s\n" \
      "${TEST_NAMES[$i]}" \
      "${TEST_STATUSES[$i]}" \
      "${PING_AVGS[$i]}ms" "${PING_P99S[$i]}ms" "${PING_MAXS[$i]}ms" \
      "${PING_LOSSES[$i]}%" \
      "${BBPERF_AVGS[$i]}ms" "${BBPERF_P99S[$i]}ms"
  done
}

echo ""
echo "========================================"
echo "  Summary: ping latency under load"
echo "  (steady-state: excluding first ${WARMUP}s warmup)"
echo "========================================"
print_summary
echo "========================================"
echo ""
echo "Results saved to: ${RESULTS_DIR}"
echo "Combined graphs:  ${RESULTS_DIR}/combined-*.png"
echo "Multi graphs:     ${RESULTS_DIR}/multi-*.png"

# Save summary to file (no banner, just the table)
print_summary > "${RESULTS_DIR}/summary.txt"
