#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Run the veth rx_notify_masked litmus tests with herd7.  Compare each
# result with the "Result:" line in the test file.
#
# Usage: ./run-herd7.sh [options] [test.litmus ...]
#
#   -k DIR   kernel source tree.  The LKMM tests need the model files in
#            DIR/tools/memory-model.  Default: $KERNEL_SRC
#   -j N     run N tests at the same time (default: number of CPUs)
#   -t SEC   time limit for each test (default: 3600)
#   -q       quick: skip the tests marked "Runtime: slow"
#   -o DIR   directory for the herd7 output.  Default: results/ for a
#            run of all tests, results-partial/ for other runs
#   -x       do not give "-optace true" to herd7.  The LKMM tests are
#            then much slower.  Use this to cross-check the results.
#   -h       show this help
#
# Without test arguments, all tests in litmus/ are run.
#
# Example:
#   eval $(opam env)                       # puts herd7 in PATH
#   ./run-herd7.sh -k ~/git/linux -q       # about one minute
#   ./run-herd7.sh -k ~/git/linux          # all tests

SCRIPTDIR="$(cd "$(dirname -- "$0")" && pwd)"

usage() {
    sed -n '4,/^$/s/^# \{0,1\}//p' "$0"
    exit "${1:-1}"
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

# Worker: run one test.  The settings come from the environment.
run_one() {
    local test="$1" name out rc

    name="$(basename "$test" .litmus)"
    out="$VMM_OUT/$name.out"
    SECONDS=0
    case "$(head -n 1 "$test")" in
    "C "*)
        # shellcheck disable=SC2086
        (cd "$VMM_LKMM" &&
         timeout "$VMM_TIMEOUT" herd7 -conf linux-kernel.cfg $VMM_OPTACE "$test") \
            > "$out.tmp" 2>&1
        rc=$?
        ;;
    "AArch64 "*)
        timeout "$VMM_TIMEOUT" herd7 "$test" > "$out.tmp" 2>&1
        rc=$?
        ;;
    *)
        echo "unknown litmus format" > "$out.tmp"
        rc=2
        ;;
    esac
    # The "Time" line is the only line that changes from run to run.
    grep -v '^Time ' "$out.tmp" > "$out"
    rm -f "$out.tmp"
    printf '%s\t%s\t%s\n' "$name" "$rc" "$SECONDS"
}

if [ "${1:-}" = "--one" ]; then
    run_one "$2"
    exit 0
fi

KSRC="${KERNEL_SRC:-}"
JOBS="$(nproc)"
TIMEOUT=3600
QUICK=0
OUT=""
OPTACE="-optace true"

while getopts "k:j:t:qo:xh" opt; do
    case "$opt" in
    k) KSRC="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    q) QUICK=1 ;;
    o) OUT="$OPTARG" ;;
    x) OPTACE="" ;;
    h) usage 0 ;;
    *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

command -v herd7 > /dev/null ||
    die "herd7 not found in PATH (opam install herdtools7; eval \$(opam env))"

# Collect the tests
TESTS=()
if [ $# -gt 0 ]; then
    for t in "$@"; do
        [ -f "$t" ] || die "no such test: $t"
        TESTS+=("$(readlink -f "$t")")
    done
else
    for t in "$SCRIPTDIR"/litmus/lkmm/*.litmus "$SCRIPTDIR"/litmus/aarch64/*.litmus; do
        if [ "$QUICK" = 1 ] && grep -q '^ \* Runtime: slow' "$t"; then
            continue
        fi
        TESTS+=("$t")
    done
fi
[ ${#TESTS[@]} -gt 0 ] || die "no tests to run"

# Only a run of all tests may replace the recorded results in results/
if [ -z "$OUT" ]; then
    if [ $# -gt 0 ] || [ "$QUICK" = 1 ]; then
        OUT="$SCRIPTDIR/results-partial"
    else
        OUT="$SCRIPTDIR/results"
    fi
fi

# The LKMM tests need the model files of a kernel tree
NEED_LKMM=0
for t in "${TESTS[@]}"; do
    case "$(head -n 1 "$t")" in
    "C "*) NEED_LKMM=1 ;;
    esac
done
LKMM=""
if [ "$NEED_LKMM" = 1 ]; then
    [ -n "$KSRC" ] || die "LKMM tests need a kernel tree: use -k DIR or set KERNEL_SRC"
    LKMM="$(readlink -f "$KSRC")/tools/memory-model"
    [ -f "$LKMM/linux-kernel.cfg" ] || die "no linux-kernel.cfg in $LKMM"
fi

mkdir -p "$OUT" || die "cannot create $OUT"
OUT="$(readlink -f "$OUT")"

export VMM_OUT="$OUT" VMM_LKMM="$LKMM" VMM_TIMEOUT="$TIMEOUT" VMM_OPTACE="$OPTACE"

echo "Running ${#TESTS[@]} tests, $JOBS at a time, time limit ${TIMEOUT}s each ..."
RUNLOG="$(mktemp)"
trap 'rm -f "$RUNLOG"' EXIT
printf '%s\0' "${TESTS[@]}" | xargs -0 -n 1 -P "$JOBS" "$0" --one > "$RUNLOG"

# Summary
SUMMARY="$OUT/summary.tsv"
printf 'test\tmodel\texpected\tobserved\tpositive\tnegative\tstatus\n' > "$SUMMARY"
TIMES=""
fail=0
printf '\n%-44s %-8s %-10s %-10s %5s %5s %6s  %s\n' \
    "test" "model" "expected" "observed" "pos" "neg" "sec" "status"
for t in "${TESTS[@]}"; do
    name="$(basename "$t" .litmus)"
    out="$OUT/$name.out"
    case "$(head -n 1 "$t")" in
    "C "*) model="LKMM" ;;
    *)     model="AArch64" ;;
    esac
    expected="$(sed -n 's/^ \* Result: *//p' "$t" | head -n 1)"
    read -r observed pos neg <<< \
        "$(sed -n 's/^Observation [^ ]* \([A-Za-z]*\) \([0-9]*\) \([0-9]*\)$/\1 \2 \3/p' "$out")"
    rc="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$RUNLOG")"
    sec="$(awk -F'\t' -v n="$name" '$1 == n { print $3 }' "$RUNLOG")"
    # herd7 reports this flag for every arm64 test that uses DMB ISH
    flags="$(grep '^Flag ' "$out" | grep -v 'Assuming-common-inner-shareable-domain')"

    if [ "$rc" = 124 ]; then
        status="TIMEOUT"
    elif [ "$rc" != 0 ] || [ -z "$observed" ]; then
        status="ERROR"
    elif [ -n "$flags" ]; then
        status="FLAG"
    elif [ "$observed" = "$expected" ]; then
        status="PASS"
    else
        status="FAIL"
    fi
    [ "$status" = "PASS" ] || fail=1

    printf '%-44s %-8s %-10s %-10s %5s %5s %6s  %s\n' \
        "$name" "$model" "$expected" "${observed:--}" "${pos:--}" "${neg:--}" "$sec" "$status"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$model" "$expected" "${observed:--}" "${pos:--}" "${neg:--}" "$status" >> "$SUMMARY"
    TIMES+="$(printf '%-44s %6s s' "$name" "$sec")"$'\n'
done

# What was used for this run.  This file changes from run to run.
{
    echo "date:        $(date -u +%Y-%m-%d)"
    echo "herd7:       $(herd7 -version | head -n 1)"
    echo "herd7 flags: ${OPTACE:-(none)} (LKMM tests only)"
    if [ -n "$LKMM" ]; then
        echo "kernel:      $(make -s -C "$LKMM/../.." kernelversion 2> /dev/null)"
        echo "LKMM files (sha256):"
        (cd "$LKMM" && sha256sum linux-kernel.bell linux-kernel.cat \
                                 linux-kernel.cfg linux-kernel.def | sed 's/^/  /')
    fi
    echo "cpu:         $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1)"
    echo "cpus:        $(nproc), $JOBS tests at a time"
    echo "time limit:  ${TIMEOUT}s"
    echo
    echo "run time of each test (wall clock):"
    printf '%s' "$TIMES"
} > "$OUT/run-info.txt"

echo
echo "herd7 output:  $OUT/*.out"
echo "summary:       $OUT/summary.tsv"
if [ "$fail" = 0 ]; then
    echo "All ${#TESTS[@]} tests gave the expected result."
else
    echo "Some tests did NOT give the expected result."
fi
exit "$fail"
