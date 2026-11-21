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
  [[ "$output" == /* ]] || false                          # absolute, not "./..."
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

# --- minimize-time cap (MINIMIZE_CAP) ----------------------------------------
# `go` is stubbed as a shell function throughout: these tests pin the runner's
# own decisions (measure, cache, threshold, flag spelling per launch path), not
# Go itself. `[[ ]] || false`: under bash 3.2 a bare [[ ]] that isn't a
# test's last command never fails it (errexit ignores [[ ]]), so it would pass
# vacuously. The real nm distance was checked by hand against a real
# instrumented binary (keyorix internal/csvsafe = 5461 bytes).

_fake_nm() {   # go tool nm output with the two counter symbols 0x1555 = 5461 apart
  printf '%s\n' \
    ' 102479340 D internal/fuzz._counters' \
    ' 10247a895 D internal/fuzz._ecounters' \
    ' 1000 T main.main'
}

@test "mapsize_of_bin: distance between _counters and _ecounters" {
  go() { [ "$1 $2" = "tool nm" ] && _fake_nm; }
  run mapsize_of_bin /fake.test
  [ "$status" -eq 0 ]
  [ "$output" = "5461" ]
}

@test "mapsize_of_bin: uninstrumented binary (no counters) -> empty, not an error" {
  go() { printf ' 1000 T main.main\n'; }
  run mapsize_of_bin /fake.test
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "minimize_cap_for: MINIMIZE_CAP off -> no flag even for a huge map" {
  pkg_map_bytes() { echo 479378; }
  MINIMIZE_CAP=off run minimize_cap_for example.com/m/internal/core
  [ -z "$output" ]
}

@test "minimize_cap_for: over threshold -> default 100x" {
  pkg_map_bytes() { echo 479378; }
  MINIMIZE_CAP=on run minimize_cap_for example.com/m/internal/core
  [ "$output" = "100x" ]
}

@test "minimize_cap_for: under threshold (csvsafe-sized) -> no flag" {
  pkg_map_bytes() { echo 5461; }
  MINIMIZE_CAP=on run minimize_cap_for example.com/m/internal/csvsafe
  [ -z "$output" ]
}

@test "minimize_cap_for: exactly at threshold -> no flag (strictly greater)" {
  pkg_map_bytes() { echo 100000; }
  MINIMIZE_CAP=on MINIMIZE_CAP_THRESHOLD=100000 run minimize_cap_for p
  [ -z "$output" ]
}

@test "minimize_cap_for: unknown size -> no flag (fail-safe)" {
  pkg_map_bytes() { :; }
  MINIMIZE_CAP=on run minimize_cap_for p
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "minimize_cap_for: custom value and threshold are honored" {
  pkg_map_bytes() { echo 60000; }
  MINIMIZE_CAP=on MINIMIZE_CAP_THRESHOLD=50000 MINIMIZE_CAP_VALUE=10x run minimize_cap_for p
  [ "$output" = "10x" ]
}

@test "pkg_map_bytes: FUZZ_PREBUILT reads the generation's mapsizes.tsv (no build)" {
  PREBUILT_DIR="$BATS_TEST_TMPDIR/pb"; PREBUILT_ACTIVE_SHA=abc; FUZZ_PREBUILT=1
  mkdir -p "$PREBUILT_DIR/abc"
  printf 'example.com/m/internal/core\t479378\n' > "$PREBUILT_DIR/abc/mapsizes.tsv"
  go() { echo "UNEXPECTED go $*" >&2; return 1; }
  run pkg_map_bytes example.com/m/internal/core
  [ "$output" = "479378" ]
}

@test "pkg_map_bytes: go-test mode measures once per source key, then serves the cache" {
  STATE_DIR="$BATS_TEST_TMPDIR/state"; LOG_DIR="$BATS_TEST_TMPDIR"; FUZZ_PREBUILT=0
  prebuilt_key() { echo key1; }
  go() {
    case "$1 $2" in
      "test -c") echo x >> "$BATS_TEST_TMPDIR/builds"; : > "${@: -2:1}" ;;  # -o <tmp>: create it
      "tool nm") _fake_nm ;;
    esac
  }
  run pkg_map_bytes example.com/m/internal/core
  [ "$output" = "5461" ]
  run pkg_map_bytes example.com/m/internal/core
  [ "$output" = "5461" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/builds")" -eq 1 ]
}

@test "pkg_map_bytes: a failed instrumented build is cached as unknown (no rebuild loop)" {
  STATE_DIR="$BATS_TEST_TMPDIR/state2"; LOG_DIR="$BATS_TEST_TMPDIR"; FUZZ_PREBUILT=0
  prebuilt_key() { echo key1; }
  go() { echo x >> "$BATS_TEST_TMPDIR/builds2"; return 1; }
  run pkg_map_bytes p
  [ -z "$output" ]
  run pkg_map_bytes p
  [ -z "$output" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/builds2")" -eq 1 ]
}

@test "pkg_map_bytes: a new source key drops the old key's cache" {
  STATE_DIR="$BATS_TEST_TMPDIR/state3"; LOG_DIR="$BATS_TEST_TMPDIR"; FUZZ_PREBUILT=0
  mkdir -p "$STATE_DIR/mapsize/oldkey"; echo 1 > "$STATE_DIR/mapsize/oldkey/p"
  prebuilt_key() { echo newkey; }
  go() { case "$1 $2" in "test -c") : > "${@: -2:1}" ;; "tool nm") _fake_nm ;; esac; }
  run pkg_map_bytes p
  [ ! -d "$STATE_DIR/mapsize/oldkey" ]
  [ -f "$STATE_DIR/mapsize/newkey/p" ]
}

@test "run_slice (go test path): passes -fuzzminimizetime only when a cap is given" {
  FUZZ_PREBUILT=0 PARALLEL=2
  go() { echo "go $*"; }
  run run_slice example.com/m/internal/core FuzzX 15m 100x
  [[ "$output" == *" -fuzzminimizetime=100x"* ]] || false
  run run_slice example.com/m/internal/csvsafe FuzzY 15m ""
  [[ "$output" != *"minimizetime"* ]] || false
}

@test "run_slice (prebuilt path): passes -test.fuzzminimizetime to the binary" {
  FUZZ_PREBUILT=1 PARALLEL=2 PREBUILT_DIR="$BATS_TEST_TMPDIR/pb2"; PREBUILT_ACTIVE_SHA=s1
  mkdir -p "$PREBUILT_DIR/s1" "$BATS_TEST_TMPDIR/src"
  printf 'example.com/m/internal/core\tcore\t%s\n' "$BATS_TEST_TMPDIR/src" > "$PREBUILT_DIR/s1/manifest.tsv"
  printf '#!/bin/sh\necho "bin $*"\n' > "$PREBUILT_DIR/s1/core.test"; chmod +x "$PREBUILT_DIR/s1/core.test"
  go() { [ "$1" = env ] && echo "$BATS_TEST_TMPDIR/gocache"; }
  run run_slice example.com/m/internal/core FuzzX 15m 100x
  [[ "$output" == *" -test.fuzzminimizetime=100x"* ]] || false
  run run_slice example.com/m/internal/core FuzzX 15m ""
  [[ "$output" != *"minimizetime"* ]] || false
}

# --- env_slug -----------------------------------------------------------------

@test "env_slug: dots and slashes become underscores (valid bash identifier)" {
  run env_slug example.com/m/internal/core
  [ "$output" = "example_com_m_internal_core" ]
}

@test "env_slug: a github.com-style import path is a valid identifier" {
  run env_slug github.com/keyorixhq/keyorix/server/http
  [ "$output" = "github_com_keyorixhq_keyorix_server_http" ]
  [[ "$output" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || false
}

# --- minimize_cap_for: per-package MINIMIZE_TIME_<slug> override -------------

@test "minimize_cap_for: per-package override wins over the computed default" {
  pkg_map_bytes() { echo 479378; }
  MINIMIZE_CAP=on MINIMIZE_CAP_VALUE=100x MINIMIZE_TIME_example_com_m_internal_core=10x \
    run minimize_cap_for example.com/m/internal/core
  [ "$output" = "10x" ]
}

@test "minimize_cap_for: per-package override of 0 is honored, not treated as unset" {
  pkg_map_bytes() { echo 479378; }
  MINIMIZE_CAP=on MINIMIZE_TIME_example_com_m_internal_core=0 \
    run minimize_cap_for example.com/m/internal/core
  [ "$output" = "0" ]
}

@test "minimize_cap_for: override only applies to its own package" {
  pkg_map_bytes() { echo 5461; }   # under threshold -- would normally be no-flag
  MINIMIZE_CAP=on MINIMIZE_TIME_example_com_m_internal_core=10x \
    run minimize_cap_for example.com/m/internal/OTHERPKG
  [ -z "$output" ]
}

@test "minimize_cap_for: no override -> falls back to computed default as before" {
  pkg_map_bytes() { echo 479378; }
  MINIMIZE_CAP=on MINIMIZE_CAP_VALUE=100x run minimize_cap_for example.com/m/internal/core
  [ "$output" = "100x" ]
}

@test "minimize_cap_for: override is still gated on MINIMIZE_CAP=on" {
  pkg_map_bytes() { echo 479378; }
  MINIMIZE_CAP=off MINIMIZE_TIME_example_com_m_internal_core=10x \
    run minimize_cap_for example.com/m/internal/core
  [ -z "$output" ]
}

# --- is_slow_target -----------------------------------------------------------

@test "is_slow_target: rate below threshold -> slow" {
  measured_exec_rate() { echo 5; }
  CONCURRENT_SLOW_THRESHOLD=20 run is_slow_target FuzzX
  [ "$status" -eq 0 ]
}

@test "is_slow_target: rate at or above threshold -> not slow" {
  measured_exec_rate() { echo 20; }
  CONCURRENT_SLOW_THRESHOLD=20 run is_slow_target FuzzX
  [ "$status" -ne 0 ]
}

@test "is_slow_target: unmeasured (0) rate -> not slow (unknown is not confirmed-slow)" {
  measured_exec_rate() { echo 0; }
  CONCURRENT_SLOW_THRESHOLD=20 run is_slow_target FuzzX
  [ "$status" -ne 0 ]
}

# --- pick_group_size -----------------------------------------------------------

@test "pick_group_size: CONCURRENT_TARGETS off -> always 1" {
  TARGETS=("pkg1|FuzzA" "pkg2|FuzzB" "pkg3|FuzzC")
  is_slow_target() { return 0; }   # even if everything is "slow"
  CONCURRENT_TARGETS=off run pick_group_size 0
  [ "$output" = 1 ]
}

@test "pick_group_size: selected target itself not slow -> 1" {
  TARGETS=("pkg1|FuzzA" "pkg2|FuzzB")
  is_slow_target() { return 1; }
  CONCURRENT_TARGETS=on run pick_group_size 0
  [ "$output" = 1 ]
}

@test "pick_group_size: contiguous run of slow targets groups up to the cap" {
  TARGETS=("pkg1|FuzzA" "pkg2|FuzzB" "pkg3|FuzzC" "pkg4|FuzzD")
  is_slow_target() { return 0; }   # everything slow
  CONCURRENT_TARGETS=on CONCURRENT_MAX_TARGETS=3 run pick_group_size 0
  [ "$output" = 3 ]
}

@test "pick_group_size: stops at the first non-slow follower (contiguous-only)" {
  TARGETS=("pkg1|FuzzA" "pkg2|FuzzB" "pkg3|FuzzC" "pkg4|FuzzD")
  is_slow_target() { [ "$1" != FuzzC ]; }   # FuzzC (index 2) is fast
  CONCURRENT_TARGETS=on CONCURRENT_MAX_TARGETS=3 run pick_group_size 0
  [ "$output" = 2 ]
}

@test "pick_group_size: never exceeds the end of TARGETS (no wrap)" {
  TARGETS=("pkg1|FuzzA" "pkg2|FuzzB" "pkg3|FuzzC")
  is_slow_target() { return 0; }
  CONCURRENT_TARGETS=on CONCURRENT_MAX_TARGETS=5 run pick_group_size 1   # only 2 entries remain (i=1,2)
  [ "$output" = 2 ]
}

@test "pick_group_size: CONCURRENT_MAX_TARGETS floors at 2" {
  TARGETS=("pkg1|FuzzA" "pkg2|FuzzB" "pkg3|FuzzC")
  is_slow_target() { return 0; }
  CONCURRENT_TARGETS=on CONCURRENT_MAX_TARGETS=1 run pick_group_size 0
  [ "$output" = 2 ]
}

@test "pick_group_size: last target in TARGETS with nothing after it -> 1" {
  TARGETS=("pkg1|FuzzA" "pkg2|FuzzB" "pkg3|FuzzC")
  is_slow_target() { return 0; }
  CONCURRENT_TARGETS=on CONCURRENT_MAX_TARGETS=3 run pick_group_size 2
  [ "$output" = 1 ]
}

# --- run_target_group -----------------------------------------------------------
# run_slice, reproducer_reverifies, handle_crash, record_saturation and
# quarantine_unverified are all stubbed: these tests pin run_target_group's OWN
# orchestration (which functions get called, how many times, with which
# arguments derived from which group member) — not go test or the real crash
# pipeline, exactly like the minimize-cap tests above pin the runner's
# decisions rather than Go itself.

@test "run_target_group: size 1 behaves exactly like the pre-concurrent single path" {
  TARGETS=("pkgA|FuzzA")
  LOG_DIR="$BATS_TEST_TMPDIR"; FINDINGS_DIR="$BATS_TEST_TMPDIR/findings"
  resolve_duration() { echo 15m; }
  MINIMIZE_CAP=off
  run_slice() { echo "ran $1 $2 $3 $4" >> "$BATS_TEST_TMPDIR/calls"; return 0; }
  record_saturation() { echo "sat $1" >> "$BATS_TEST_TMPDIR/calls"; }
  run run_target_group 0 1
  [ "$status" -eq 0 ]
  grep -q '^ran pkgA FuzzA 15m $' "$BATS_TEST_TMPDIR/calls"
  grep -q '^sat FuzzA$' "$BATS_TEST_TMPDIR/calls"
}

@test "run_target_group: size 2 runs both members and records saturation for both" {
  TARGETS=("pkgA|FuzzA" "pkgB|FuzzB")
  LOG_DIR="$BATS_TEST_TMPDIR"; FINDINGS_DIR="$BATS_TEST_TMPDIR/findings"
  resolve_duration() { echo 15m; }
  MINIMIZE_CAP=off
  run_slice() { echo "ran $2" >> "$BATS_TEST_TMPDIR/calls"; return 0; }
  record_saturation() { echo "sat $1" >> "$BATS_TEST_TMPDIR/calls"; }
  run run_target_group 0 2
  [ "$status" -eq 0 ]
  grep -q '^ran FuzzA$' "$BATS_TEST_TMPDIR/calls"
  grep -q '^ran FuzzB$' "$BATS_TEST_TMPDIR/calls"
  grep -q '^sat FuzzA$' "$BATS_TEST_TMPDIR/calls"
  grep -q '^sat FuzzB$' "$BATS_TEST_TMPDIR/calls"
}

@test "run_target_group: a reproducer dir for one member triggers handle_crash for THAT member only" {
  TARGETS=("pkgA|FuzzA" "pkgB|FuzzB")
  LOG_DIR="$BATS_TEST_TMPDIR"; FINDINGS_DIR="$BATS_TEST_TMPDIR/findings"
  resolve_duration() { echo 15m; }
  MINIMIZE_CAP=off REVERIFY_CRASH=off
  mkdir -p "$BATS_TEST_TMPDIR/sub/testdata/fuzz/FuzzA"
  echo x > "$BATS_TEST_TMPDIR/sub/testdata/fuzz/FuzzA/repro1"
  cd "$BATS_TEST_TMPDIR/sub"
  run_slice() { return 1; }
  handle_crash() { echo "crash $1 $2 $3" >> "$BATS_TEST_TMPDIR/calls"; }
  record_saturation() { :; }
  run run_target_group 0 2
  [ "$status" -eq 0 ]
  grep -q '^crash FuzzA pkgA 1$' "$BATS_TEST_TMPDIR/calls"
  ! grep -q 'crash FuzzB' "$BATS_TEST_TMPDIR/calls"
}

@test "run_target_group: unverified reproducer quarantines instead of alerting" {
  TARGETS=("pkgA|FuzzA")
  LOG_DIR="$BATS_TEST_TMPDIR"; FINDINGS_DIR="$BATS_TEST_TMPDIR/findings"
  resolve_duration() { echo 15m; }
  MINIMIZE_CAP=off REVERIFY_CRASH=on
  mkdir -p "$BATS_TEST_TMPDIR/sub2/testdata/fuzz/FuzzA"
  echo x > "$BATS_TEST_TMPDIR/sub2/testdata/fuzz/FuzzA/repro1"
  cd "$BATS_TEST_TMPDIR/sub2"
  run_slice() { return 1; }
  reproducer_reverifies() { return 1; }   # transient
  handle_crash() { echo "SHOULD NOT BE CALLED" >> "$BATS_TEST_TMPDIR/calls"; }
  quarantine_unverified() { echo "quarantined $1" >> "$BATS_TEST_TMPDIR/calls"; }
  record_saturation() { :; }
  run run_target_group 0 1
  [ "$status" -eq 0 ]
  grep -q '^quarantined FuzzA$' "$BATS_TEST_TMPDIR/calls"
  ! grep -q 'SHOULD NOT' "$BATS_TEST_TMPDIR/calls"
}

# --- stall_summary -----------------------------------------------------------

@test "stall_summary is silent when the slice saw no freezes" {
  LOG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$LOG_DIR/stalls"; : >"$LOG_DIR/stalls/FuzzA.stalls"
  run stall_summary FuzzA
  [ "$status" -eq 0 ]
  [ ! -e "$LOG_DIR/stalls.tsv" ]
}

@test "stall_summary reports count, max and total across go duration formats" {
  LOG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$LOG_DIR/stalls"
  cat >"$LOG_DIR/stalls/FuzzA.stalls" <<'EOF'
2026-11-18T00:00:01Z pid=1 exe=a.test frozen=700ms
2026-11-18T00:00:09Z pid=1 exe=a.test frozen=12.5s
2026-11-18T00:01:09Z pid=2 exe=a.test frozen=1m2s
EOF
  run stall_summary FuzzA
  [ "$status" -eq 0 ]
  [[ "$output" == *"stalls: FuzzA 3 62.0 75.2"* ]]
  run cut -f2-5 "$LOG_DIR/stalls.tsv"
  [ "$output" = "$(printf 'FuzzA\t3\t62.0\t75.2')" ]
}

# --- EXTRA_MODULES (nested modules in the rotation) ---------------------------

# Root module with one Fuzz target plus a nested module (own go.mod, not in any
# go.work) with another; stdlib only, so no network.
_extra_fixture() {
  FIX="$BATS_TEST_TMPDIR/mod"; mkdir -p "$FIX/rootpkg" "$FIX/sub/subpkg" "$BATS_TEST_TMPDIR/state"
  printf 'module example.com/mod\n\ngo 1.22\n' >"$FIX/go.mod"
  printf 'module example.com/mod/sub\n\ngo 1.22\n' >"$FIX/sub/go.mod"
  printf 'package rootpkg\n\nimport "testing"\n\nfunc FuzzRoot(f *testing.F) { f.Fuzz(func(t *testing.T, b []byte) {}) }\n' >"$FIX/rootpkg/r_test.go"
  printf 'package subpkg\n\nimport "testing"\n\nfunc FuzzSub(f *testing.F) { f.Fuzz(func(t *testing.T, b []byte) {}) }\n' >"$FIX/sub/subpkg/s_test.go"
  MODULE_DIR="$FIX"; STATE_DIR="$BATS_TEST_TMPDIR/state"
  unset GOWORK
}

@test "discover without EXTRA_MODULES does not see a nested module's targets" {
  _extra_fixture
  EXTRA_MODULES=""
  cd "$FIX"
  run discover
  [[ "$output" == *"example.com/mod/rootpkg|FuzzRoot"* ]]
  [[ "$output" != *"FuzzSub"* ]]
}

@test "discover with EXTRA_MODULES includes the nested module's targets" {
  _extra_fixture
  EXTRA_MODULES="sub"
  setup_extra_modules
  cd "$FIX"
  run discover
  [[ "$output" == *"example.com/mod/rootpkg|FuzzRoot"* ]]
  [[ "$output" == *"example.com/mod/sub/subpkg|FuzzSub"* ]]
}

@test "setup_extra_modules writes the workspace outside the checkout and skips a dir with no go.mod" {
  _extra_fixture
  EXTRA_MODULES="sub nonexistent"
  run setup_extra_modules
  [ "$status" -eq 0 ]
  setup_extra_modules 2>/dev/null
  [ "$GOWORK" = "$STATE_DIR/extra-modules.go.work" ]
  grep -q "$FIX/sub" "$GOWORK"
  ! grep -q nonexistent "$GOWORK"
}
