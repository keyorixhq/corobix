#!/usr/bin/env bash
# exit-classify.sh: tell a normal `go test` failure (clean Go-level non-zero
# exit; the fuzz engine itself found and saved a reproducer) apart from a
# process killed outright by a signal -- which, from a Go test binary, means
# the OS ended it, not Go's own recover()/testing machinery. That is the
# signature of a crash reaching across a cgo boundary (the classic case) or
# an OOM kill, and it means the triggering input may not have been written
# to testdata/fuzz/<Func>/ the way a clean Go-detected crash would be.
#
# Deliberately detection-only: it does NOT retry per-input to find which
# corpus entry caused it (that would mean one subprocess per fuzz execution,
# which is the opposite of what makes `go test -fuzz` fast -- thousands of
# execs/sec in one process, not one process per input). Bisecting after a
# signal death, if wanted, is a separate, explicitly opt-in step.
#
# Usage: classify_exit <rc>
#   prints "normal" for an ordinary exit code (0-128)
#   prints "signal:<N>:<NAME>" for a code in 129-192 -- bash's own encoding
#   (128+signal) for a job that `wait` reports as killed by a signal.
classify_exit() {
  local rc="${1:-0}" sig name
  if [ "$rc" -gt 128 ] && [ "$rc" -lt 193 ]; then
    sig=$(( rc - 128 ))
    name="$(kill -l "$sig" 2>/dev/null)"; name="${name:-SIG$sig}"
    printf 'signal:%d:%s\n' "$sig" "$name"
  else
    echo normal
  fi
}

# is_signal_death <rc> -> exit 0 (true) iff classify_exit says "signal:...".
is_signal_death() {
  case "$(classify_exit "${1:-0}")" in signal:*) return 0 ;; *) return 1 ;; esac
}
