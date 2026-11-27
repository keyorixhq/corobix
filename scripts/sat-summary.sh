#!/usr/bin/env bash
# sat-summary.sh — one table of how far each fuzz rig has got: per rig, how many
# targets are saturated, still active, or too young to judge.
#
# WHY: the ntfy saturation report is per rig and ntfy keeps ~12 h, so a quiet topic
# reads as "everything found" when most targets are still growing or barely ran.
# This reads the same $STATE_DIR/sat/<fn> history the runner's is_saturated uses
# (one line per recorded run: that run's final "new interesting" count), over ssh.
#
# Verdict per target (CONFIRM_MIN_RUNS, default 3, as in the runner):
#   saturated  >= MIN runs and the recorded history sums to 0
#   active     >= MIN runs and the history sums to > 0
#   young      fewer than MIN runs (not enough runs to judge)
#
# Usage: scripts/sat-summary.sh [-t N] [rig...]    rigs: keyorix dashdiag libs-extra libs
#   -t N   also list the N most active targets per rig (default 5, 0 = none)
#   SAT_FILE=<path>  read "fn runs sum10 total" lines from a file instead of ssh
#                    (tests); the rig name is then taken from the first argument.
set -euo pipefail

CONFIRM_MIN_RUNS="${CONFIRM_MIN_RUNS:-3}"

# rig -> "ssh_host|state_dir"  (state dirs per each rig's fuzz.conf; keyorix keeps its
# state under /opt/keyorix-fuzz because its conf does not set STATE_DIR)
rig_state() {
  case "$1" in
    keyorix)    echo "vcd-keyorix-fuzz|/opt/keyorix-fuzz/harness-state" ;;
    dashdiag)   echo "vcd-dashdiag-fuzz|/home/andrei/proj/dashdiag-harness-state" ;;
    libs-extra) echo "vcd-dashdiag-fuzz|/home/andrei/proj/libs-extra-harness-state" ;;
    libs)       echo "pve01|/root/libs-fuzz-state" ;;
    *) return 1 ;;
  esac
}

# collect <ssh_host> <state_dir> -> "fn runs sum10 total" lines
collect() {
  ssh -o ConnectTimeout=15 -o BatchMode=yes "$1" bash -s -- "$2" <<'REMOTE'
for f in "$1"/sat/*; do
  [ -f "$f" ] || continue
  awk -v fn="$(basename "$f")" '{a[NR]=$1; t+=$1} END{n=NR; s=0; for(i=(n>10?n-9:1);i<=n;i++) s+=a[i]; print fn, n, s, t+0}' "$f"
done
REMOTE
}

# summarize <rig> <top_n>   reads "fn runs sum10 total" on stdin
summarize() {
  awk -v rig="$1" -v top="$2" -v min="$CONFIRM_MIN_RUNS" '
    { fn=$1; n=$2; s10=$3; tot=$4; count++
      if (n < min) young++
      else if (tot == 0) sat++
      else { act++; name[act]=fn; val[act]=s10 } }
    END {
      printf "%-11s targets=%-4d saturated=%-4d active=%-4d young(<%d runs)=%d\n", rig, count, sat, act, min, young
      for (k=0; k<top && act>0; k++) {          # selection of the top-N most active
        best=0
        for (i=1;i<=act;i++) if (val[i]>val[best] || best==0) if (!(i in used)) best=i
        if (!best) break
        used[best]=1
        printf "    +%-6d %s\n", val[best], name[best]
      }
    }'
}

main() {
  local top=5
  if [ "${1:-}" = "-t" ]; then top="$2"; shift 2; fi
  if [ -n "${SAT_FILE:-}" ]; then
    summarize "${1:-rig}" "$top" < "$SAT_FILE"
    return
  fi
  local rigs=("$@") rig spec
  [ "${#rigs[@]}" -gt 0 ] || rigs=(keyorix dashdiag libs-extra libs)
  for rig in "${rigs[@]}"; do
    spec="$(rig_state "$rig")" || { echo "sat-summary: unknown rig '$rig'" >&2; exit 2; }
    if ! collect "${spec%%|*}" "${spec##*|}" | summarize "$rig" "$top"; then
      echo "$rig: unreachable" >&2
    fi
  done
}

main "$@"
