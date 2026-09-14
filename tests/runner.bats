#!/usr/bin/env bats
# Unit tests for the pure functions in fuzz-runner.sh.
# The runner returns before main() when FUZZ_RUNNER_LIB is set, so we can source
# it to get the functions without launching a rotation.

setup() {
  FUZZ_RUNNER_LIB=1 source "${BATS_TEST_DIRNAME}/../fuzz-runner.sh"
}

# --- resolve_duration --------------------------------------------------------

@test "resolve_duration falls back to DEFAULT_FUZZTIME when no override" {
  DEFAULT_FUZZTIME=15m
  run resolve_duration FuzzSomething
  [ "$status" -eq 0 ]
  [ "$output" = "15m" ]
}

@test "resolve_duration uses a per-target DURATION_<fn> override" {
  DEFAULT_FUZZTIME=1h
  DURATION_FuzzVerifyReceipt=3h
  run resolve_duration FuzzVerifyReceipt
  [ "$output" = "3h" ]
}

@test "resolve_duration override applies only to the named target" {
  DEFAULT_FUZZTIME=1h
  DURATION_FuzzVerifyReceipt=3h
  run resolve_duration FuzzOther
  [ "$output" = "1h" ]
}

# --- effective_report_mode ---------------------------------------------------

@test "git + pr stays pr (public PR allowed for own code)" {
  SOURCE_MODE=git REPORT_MODE=pr
  run effective_report_mode
  [ "$output" = "pr" ]
}

@test "standalone + pr downgrades to private when CORPUS_REPO is set" {
  SOURCE_MODE=standalone REPORT_MODE=pr CORPUS_REPO=git@github.com:keyorixhq/fuzz-corpus.git
  run effective_report_mode
  [ "$output" = "private" ]
}

@test "standalone + pr downgrades to local when no CORPUS_REPO" {
  SOURCE_MODE=standalone REPORT_MODE=pr CORPUS_REPO=
  run effective_report_mode
  [ "$output" = "local" ]
}

@test "standalone + pr + ALLOW_PR_FOR_STANDALONE=1 stays pr" {
  SOURCE_MODE=standalone REPORT_MODE=pr ALLOW_PR_FOR_STANDALONE=1
  run effective_report_mode
  [ "$output" = "pr" ]
}

@test "git + issue stays issue (public issue allowed for own code)" {
  SOURCE_MODE=git REPORT_MODE=issue
  run effective_report_mode
  [ "$output" = "issue" ]
}

@test "standalone + issue downgrades to private when CORPUS_REPO is set" {
  SOURCE_MODE=standalone REPORT_MODE=issue CORPUS_REPO=git@github.com:keyorixhq/fuzz-corpus.git
  run effective_report_mode
  [ "$output" = "private" ]
}

@test "standalone + issue downgrades to local when no CORPUS_REPO" {
  SOURCE_MODE=standalone REPORT_MODE=issue CORPUS_REPO=
  run effective_report_mode
  [ "$output" = "local" ]
}

@test "standalone + issue + ALLOW_PUBLIC_FOR_STANDALONE=1 stays issue" {
  SOURCE_MODE=standalone REPORT_MODE=issue ALLOW_PUBLIC_FOR_STANDALONE=1
  run effective_report_mode
  [ "$output" = "issue" ]
}

@test "deprecated CRASH_MODE is honored when REPORT_MODE is unset" {
  SOURCE_MODE=git CRASH_MODE=pr
  run effective_report_mode
  [ "$output" = "pr" ]
}

@test "REPORT_MODE wins over a stale CRASH_MODE" {
  SOURCE_MODE=git REPORT_MODE=private CRASH_MODE=pr
  run effective_report_mode
  [ "$output" = "private" ]
}

@test "private stays private for standalone" {
  SOURCE_MODE=standalone REPORT_MODE=private CORPUS_REPO=git@github.com:keyorixhq/fuzz-corpus.git
  run effective_report_mode
  [ "$output" = "private" ]
}

@test "private stays private for git" {
  SOURCE_MODE=git REPORT_MODE=private CORPUS_REPO=git@github.com:keyorixhq/fuzz-corpus.git
  run effective_report_mode
  [ "$output" = "private" ]
}

@test "standalone + local stays local" {
  SOURCE_MODE=standalone REPORT_MODE=local
  run effective_report_mode
  [ "$output" = "local" ]
}

@test "git + local stays local" {
  SOURCE_MODE=git REPORT_MODE=local
  run effective_report_mode
  [ "$output" = "local" ]
}

@test "report mode defaults to local when unset" {
  SOURCE_MODE=git
  run effective_report_mode
  [ "$output" = "local" ]
}

# --- filter_targets ----------------------------------------------------------

@test "filter_targets passes everything through when EXCLUDE is empty" {
  result="$(printf 'p|FuzzA\np|FuzzB\n' | EXCLUDE='' filter_targets)"
  [ "$result" = "$(printf 'p|FuzzA\np|FuzzB')" ]
}

@test "filter_targets drops an excluded func" {
  result="$(printf 'p|FuzzA\np|FuzzB\np|FuzzC\n' | EXCLUDE='FuzzB' filter_targets)"
  [ "$result" = "$(printf 'p|FuzzA\np|FuzzC')" ]
}

@test "filter_targets drops multiple excluded funcs" {
  result="$(printf 'p|FuzzA\np|FuzzB\np|FuzzC\n' | EXCLUDE='FuzzA FuzzC' filter_targets)"
  [ "$result" = "p|FuzzB" ]
}

@test "filter_targets matches whole func names only (no prefix match)" {
  result="$(printf 'p|FuzzJWTParseIDToken\n' | EXCLUDE='FuzzJWT' filter_targets)"
  [ "$result" = "p|FuzzJWTParseIDToken" ]
}

# --- sat_verdict -------------------------------------------------------------

@test "sat_verdict: fewer than 3 runs is warming" {
  run sat_verdict 2 0
  [ "$output" = "warming (2 runs)" ]
}

@test "sat_verdict: 3+ runs with zero growth is SATURATED" {
  run sat_verdict 10 0
  [ "$output" = "SATURATED (+0 over 10 runs)" ]
}

@test "sat_verdict: 3+ runs with growth is active" {
  run sat_verdict 5 7
  [ "$output" = "active (+7 over 5 runs)" ]
}

# --- _stage_crasher (regression: must work from a foreign CWD) ----------------
# Guards the bug where handle_crash passed a module-relative src that no longer
# resolved after push_to_main cd'd into the corpus checkout, so crasher staging
# silently failed while the local findings copy survived.

@test "_stage_crasher stages from an absolute CRASH_SRC when CWD is elsewhere" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  src="$BATS_TEST_TMPDIR/mod/testdata/fuzz/FuzzX"
  mkdir -p "$src"; echo "repro-bytes" > "$src/seed1"
  repo="$BATS_TEST_TMPDIR/corpus-main"; mkdir -p "$repo"
  CORPUS_PROJECT=libs-extra CRASH_PKG=keyorix-libs-extra-fuzz CRASH_FN=FuzzX CRASH_TS=20260913T000000Z
  CRASH_SRC="$src"
  cd "$repo"
  run _stage_crasher
  [ "$status" -eq 0 ]
  [ -f "$repo/crashers/libs-extra/keyorix-libs-extra-fuzz/FuzzX/20260913T000000Z/seed1" ]
}

@test "_stage_crasher fails (non-zero) when CRASH_SRC does not resolve from CWD" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  repo="$BATS_TEST_TMPDIR/corpus-main2"; mkdir -p "$repo"
  CORPUS_PROJECT=libs-extra CRASH_PKG=pkg CRASH_FN=FuzzY CRASH_TS=t
  CRASH_SRC="./does/not/exist"
  cd "$repo"
  run _stage_crasher
  [ "$status" -ne 0 ]
}

@test "_find_repro_dir returns an ABSOLUTE path (locks the relative-src bug)" {
  # The bug: handle_crash resolved src with 'find .', a module-relative path that
  # broke once push_to_main cd'd into the corpus checkout. It must be absolute.
  mod="$BATS_TEST_TMPDIR/mod"
  mkdir -p "$mod/testdata/fuzz/FuzzZ"; echo x > "$mod/testdata/fuzz/FuzzZ/seed"
  cd "$mod"
  run _find_repro_dir FuzzZ
  [ "$status" -eq 0 ]
  [[ "$output" == /* ]]                                   # absolute, not "./..."
  [ "$output" = "$mod/testdata/fuzz/FuzzZ" ]
}

# --- dur_to_secs -------------------------------------------------------------

@test "dur_to_secs parses h/m/s, combos, and bare integers" {
  run dur_to_secs 15m;    [ "$output" = 900 ]
  run dur_to_secs 2h;     [ "$output" = 7200 ]
  run dur_to_secs 90s;    [ "$output" = 90 ]
  run dur_to_secs 1h30m;  [ "$output" = 5400 ]
  run dur_to_secs 120;    [ "$output" = 120 ]
  run dur_to_secs "";     [ "$output" = 0 ]
}

# --- is_saturated ------------------------------------------------------------
# Helper: seed a target's saturation history + last-run log used by the
# exec-rate-scaled confirmation path.
_seed() {  # _seed <fn> <sat-lines-newline-sep> <ratePerSec> <warmupGoDur>
  STATE_DIR="$BATS_TEST_TMPDIR/state"; LOG_DIR="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$STATE_DIR/sat" "$LOG_DIR"
  printf '%b' "$2" > "$STATE_DIR/sat/$1"
  {
    [ -n "$4" ] && echo "fuzz: elapsed: $4, gathering baseline coverage: 7/7 completed, now fuzzing with 6 workers"
    [ -n "$3" ] && echo "fuzz: elapsed: 30s, execs: 999 ($3/sec)"
    echo "fuzz: elapsed: 15m0s, execs: 9999 (0/sec)"   # final tick is 0/sec — must be skipped
  } > "$LOG_DIR/$1.log"
}

@test "is_saturated: 3+ zero-growth runs is saturated; growth or too-few is not" {
  _seed FuzzSat "0\n0\n0\n" "" ""
  run is_saturated FuzzSat;   [ "$status" -eq 0 ]
  _seed FuzzActive "0\n5\n0\n" "" ""
  run is_saturated FuzzActive; [ "$status" -ne 0 ]
  _seed FuzzWarm "0\n0\n" "" ""       # only 2 runs
  run is_saturated FuzzWarm;  [ "$status" -ne 0 ]
}

# --- resolve_duration: exec-rate-scaled confirmation slices -------------------

@test "resolve_duration: REWEIGHT off keeps the configured budget even when saturated" {
  _seed FuzzX "0\n0\n0\n" 50000 1s
  DEFAULT_FUZZTIME=15m REWEIGHT_CONFIRM=off run resolve_duration FuzzX
  [ "$output" = 15m ]
}

@test "resolve_duration: saturated fast parser collapses to a short exec-budgeted slice" {
  _seed FuzzFast "0\n0\n0\n" 50000 1s      # 5,000,000 / 50,000 = 100s; floor 10s; min 60s
  DEFAULT_FUZZTIME=15m REWEIGHT_CONFIRM=on run resolve_duration FuzzFast
  [ "$output" = 100s ]
}

@test "resolve_duration: saturated slow/crypto target stays proportionally longer (capped)" {
  _seed FuzzSlow "0\n0\n0\n" 5000 16s      # 5,000,000 / 5,000 = 1000s; warmup floor 160s
  DURATION_FuzzSlow=3h REWEIGHT_CONFIRM=on run resolve_duration FuzzSlow
  [ "$output" = 1000s ]
}

@test "resolve_duration: CONFIRM_MIN_SLICE is the absolute floor" {
  _seed FuzzTiny "0\n0\n0\n" 100000000 1s  # budget rounds to ~0s -> clamped to min
  DEFAULT_FUZZTIME=15m REWEIGHT_CONFIRM=on CONFIRM_MIN_SLICE=60 run resolve_duration FuzzTiny
  [ "$output" = 60s ]
}

@test "resolve_duration: confirmation never exceeds the configured budget" {
  _seed FuzzShortCfg "0\n0\n0\n" 50000 1s  # budget 100s but configured is only 30s
  DEFAULT_FUZZTIME=30s REWEIGHT_CONFIRM=on run resolve_duration FuzzShortCfg
  [ "$output" = 30s ]
}

@test "resolve_duration: a still-active target keeps its full configured budget" {
  _seed FuzzGrowing "0\n5\n0\n" 50000 1s
  DEFAULT_FUZZTIME=15m REWEIGHT_CONFIRM=on run resolve_duration FuzzGrowing
  [ "$output" = 15m ]
}

@test "resolve_duration: saturated but no measured rate falls back to configured (fail-safe)" {
  _seed FuzzNoRate "0\n0\n0\n" "" ""       # no exec-rate tick in the log
  DEFAULT_FUZZTIME=15m REWEIGHT_CONFIRM=on run resolve_duration FuzzNoRate
  [ "$output" = 15m ]
}

# --- reproducer_reverifies (crash re-verify guard) ---------------------------

@test "reproducer_reverifies: replay re-fails -> REAL crash (returns 0)" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  go() { return 1; }                       # stub: the saved input fails on replay
  run reproducer_reverifies FuzzX ./pkg
  [ "$status" -eq 0 ]
}

@test "reproducer_reverifies: replay passes -> TRANSIENT (returns nonzero)" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  go() { return 0; }                       # stub: replays clean
  REVERIFY_RUNS=1 run reproducer_reverifies FuzzX ./pkg
  [ "$status" -ne 0 ]
}

@test "reproducer_reverifies: ANY failure across REVERIFY_RUNS counts as reproduced" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  go() {                                    # fail only on the 2nd of 3 replays
    local c="$BATS_TEST_TMPDIR/goc" n
    n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
    [ "$n" -eq 2 ] && return 1 || return 0
  }
  REVERIFY_RUNS=3 run reproducer_reverifies FuzzX ./pkg
  [ "$status" -eq 0 ]
}

@test "reproducer_reverifies: all REVERIFY_RUNS clean -> transient" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  go() { return 0; }
  REVERIFY_RUNS=3 run reproducer_reverifies FuzzX ./pkg
  [ "$status" -ne 0 ]
}
