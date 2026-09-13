#!/usr/bin/env bash
# One-off: does the universal runner's discover() match dashdiag's own
# fuzz-discover.sh ("all" set) on this Linux box?
set -uo pipefail
export PATH=/snap/bin:$PATH
export FUZZ_RUNNER_LIB=1
# shellcheck disable=SC1091
source /home/andrei/proj/fuzz-harness/fuzz-runner.sh
cd /home/andrei/proj/dashdiag || exit 1
echo "===DISCOVER (universal: pkg|Func)==="
discover | awk -F'|' '{n=split($1,a,"/"); print a[n]"|"$2}' | sort > /tmp/d_uni.txt
cat /tmp/d_uni.txt
echo "===DISCOVER (dashdiag fuzz-discover.sh all: pkg|Func)==="
scripts/fuzz-discover.sh all | awk -F: '{n=split($2,a,"/"); print a[n]"|"$1}' | sort > /tmp/d_dd.txt
cat /tmp/d_dd.txt
echo "===DIFF (dashdiag vs universal)==="
if diff -u /tmp/d_dd.txt /tmp/d_uni.txt; then echo IDENTICAL; else echo DIFFERS; fi
echo "counts: universal=$(wc -l </tmp/d_uni.txt) dashdiag=$(wc -l </tmp/d_dd.txt)"
