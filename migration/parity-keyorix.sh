#!/usr/bin/env bash
# One-off: does the universal runner's discover() match the live targets.conf?
set -uo pipefail
export PATH=/snap/bin:$PATH
export FUZZ_RUNNER_LIB=1
# shellcheck disable=SC1091
source /home/andrei/proj/fuzz-harness/fuzz-runner.sh
cd /opt/keyorix-fuzz/keyorix || exit 1
echo "===DISCOVER==="
discover | sort > /tmp/disc.txt
cat /tmp/disc.txt
echo "===TARGETSCONF==="
grep -vE '^#|^$' scripts/fuzzing/targets.conf | awk -F'|' '{print $1"|"$2}' | sort > /tmp/tconf.txt
cat /tmp/tconf.txt
echo "===DIFF==="
if diff -u /tmp/tconf.txt /tmp/disc.txt; then
  echo IDENTICAL
else
  echo DIFFERS
fi
