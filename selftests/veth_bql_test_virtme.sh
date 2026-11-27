#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Launch veth BQL test inside virtme-ng
#
# Must be run from a compiled kernel build tree (needs vmlinux).
# Builds C tools on the host, creates a timestamped results directory,
# then boots a VM and runs the inner test.
#
# Options:
#   --verbose       Show kernel console (vng boot messages) in real time.
#                   Useful for debugging kernel panics / BUG_ON crashes.
#   --run IMAGE     Boot this kernel image instead of the tree's bzImage.
#                   vng takes modules from the nearest lib/modules above
#                   IMAGE, e.g. signed modules from 'make modules_install
#                   INSTALL_MOD_PATH=vng-root' for MODULE_SIG_FORCE kernels.
#   All other options are forwarded to veth_bql_test.sh (see --help there).
#
# Examples (run from kernel tree root):
#   cd /path/to/kernel && /path/to/veth_bql_test_virtme.sh [OPTIONS]
#     --qdisc fq_codel --hist
#     --qdisc sfq --bql-disable
#     --verbose --qdisc-replace --duration 60

set -eu

# Parse --verbose and --run (consumed here for vng, not forwarded).
# --hist is forwarded to the inner test for bpftrace histogram output.
ORIG_ARGS="$*"
VERBOSE=""
RUN_ARGS=()
INNER_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
    --verbose) VERBOSE="--verbose"; shift ;;
    --run)
        [ -f "${2:-}" ] || { echo "ERROR: --run needs a kernel image file" >&2; exit 1; }
        RUN_ARGS=(--run "$(readlink -f "$2")"); shift 2 ;;
    *) INNER_ARGS+=("$1"); shift ;;
    esac
done
TEST_ARGS=""
[ ${#INNER_ARGS[@]} -gt 0 ] && TEST_ARGS=$(printf '%q ' "${INNER_ARGS[@]}")

if [ ! -f "vmlinux" ]; then
    echo "ERROR: virtme-ng needs vmlinux; run from a compiled kernel tree:" >&2
    echo "  cd /path/to/kernel && $0" >&2
    exit 1
fi

# Verify .config has the options needed for virtme-ng and this test.
# Without these the VM silently stalls with no output.
KCONFIG=".config"
if [ ! -f "$KCONFIG" ]; then
    echo "ERROR: No .config found -- build the kernel first" >&2
    exit 1
fi

MISSING=""
for opt in CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_NET \
           CONFIG_VIRTIO_CONSOLE CONFIG_NET_9P CONFIG_NET_9P_VIRTIO \
           CONFIG_9P_FS CONFIG_VETH CONFIG_BQL; do
    if ! grep -q "^${opt}=[ym]" "$KCONFIG"; then
        MISSING+="  $opt\n"
    fi
done
if [ -n "$MISSING" ]; then
    echo "ERROR: .config is missing options required by virtme-ng:" >&2
    echo -e "$MISSING" >&2
    echo "Consider: vng --kconfig (or make defconfig + enable above)" >&2
    exit 1
fi

# Locate selftest scripts relative to this wrapper.
SCRIPTDIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$SCRIPTDIR")"
TESTNAME="veth_bql_test.sh"

# Build C tools on the host (binaries visible inside VM via --rwdir).
echo "Building tools..."
make -C "$SCRIPTDIR" || { echo "ERROR: make failed" >&2; exit 1; }

# Create timestamped results directory on host (persisted via --rwdir).
export RESULTSDIR="$REPO_ROOT/results/selftests/$(date +%Y-%m-%dT%H-%M-%S)"
mkdir -p "$RESULTSDIR"
ln -sfn "$(basename "$RESULTSDIR")" "$REPO_ROOT/results/selftests/latest"

LOGFILE="$RESULTSDIR/veth_bql_test.log"
CONSOLELOG="$RESULTSDIR/veth_bql_console.log"

# Record command line for easy re-run (copy-paste ready)
echo "cd $(pwd) && $0 $ORIG_ARGS" > "$RESULTSDIR/cmdline.sh"

echo "Starting VM..."
echo "  kernel tree: $(pwd)"
echo "  selftest dir: $SCRIPTDIR"
echo "  results dir: $RESULTSDIR"
echo "(VM is booting, please wait ~30s)"

# Always capture kernel console to a file via a second QEMU serial port.
# vng claims ttyS0 (mapped to /dev/null); --qemu-opts adds ttyS1 on COM2.
# earlycon registers COM2's I/O port (0x2f8) as a persistent console.
# (plain console=ttyS1 does NOT work: the 8250 driver registers once,
# ttyS0 wins, and ttyS1 is never picked up.)
# --verbose additionally shows kernel console in real time on the terminal.
SERIAL_CONSOLE="earlycon=uart8250,io,0x2f8,115200"
SERIAL_CONSOLE+=" console=uart8250,io,0x2f8,115200"
set +e
vng $VERBOSE "${RUN_ARGS[@]}" --cpus 4 --memory 2G \
    --rwdir "$REPO_ROOT" \
    --append "panic=5 loglevel=4 $SERIAL_CONSOLE" \
    --qemu-opts="-serial file:$CONSOLELOG" \
    --exec "cd $SCRIPTDIR && \
        RESULTSDIR=$RESULTSDIR ./$TESTNAME $TEST_ARGS 2>&1 | \
        tee $RESULTSDIR/veth_bql_test.log; echo EXIT_CODE=\$? >> $RESULTSDIR/veth_bql_test.log"
VNG_RC=$?
set -e

echo ""
if [ "$VNG_RC" -ne 0 ]; then
    echo "***********************************************************"
    echo "* VM CRASHED -- kernel panic or BUG_ON (vng rc=$VNG_RC)"
    echo "***********************************************************"
    if [ -s "$CONSOLELOG" ] && \
       grep -qiE 'kernel BUG|BUG:|Oops:|panic|dql_completed' "$CONSOLELOG"; then
        echo ""
        echo "--- kernel backtrace ($CONSOLELOG) ---"
        grep -iE -A30 'kernel BUG|BUG:|Oops:|panic|dql_completed' \
            "$CONSOLELOG" | head -50
    else
        echo ""
        echo "Re-run with --verbose to see the kernel backtrace:"
        echo "  $0 --verbose ${INNER_ARGS[*]}"
    fi
    exit 1
elif [ ! -f "$LOGFILE" ]; then
    echo "No log file found -- VM may have crashed before writing output"
    exit 2
else
    echo "=== VM finished ==="
    echo "Results: $RESULTSDIR"
fi

# Scan console log for unexpected kernel warnings (even on clean exit)
if [ -s "$CONSOLELOG" ]; then
    WARN_PATTERN='kernel BUG|BUG:|Oops:|dql_completed|WARNING:|asks to queue packet|NETDEV WATCHDOG'
    WARN_LINES=$(grep -cE "$WARN_PATTERN" "$CONSOLELOG" 2>/dev/null) || WARN_LINES=0
    if [ "$WARN_LINES" -gt 0 ]; then
        echo ""
        echo "*** kernel warnings in $CONSOLELOG ($WARN_LINES lines) ***"
        grep -E "$WARN_PATTERN" "$CONSOLELOG" | head -20
    fi
fi
