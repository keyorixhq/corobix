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

# --- effective_crash_mode ----------------------------------------------------

@test "git + pr stays pr (public PR allowed for own code)" {
  SOURCE_MODE=git CRASH_MODE=pr
  run effective_crash_mode
  [ "$output" = "pr" ]
}

@test "standalone + pr downgrades to private when CORPUS_REPO is set" {
  SOURCE_MODE=standalone CRASH_MODE=pr CORPUS_REPO=git@github.com:keyorixhq/fuzz-corpus.git
  run effective_crash_mode
  [ "$output" = "private" ]
}

@test "standalone + pr downgrades to local when no CORPUS_REPO" {
  SOURCE_MODE=standalone CRASH_MODE=pr CORPUS_REPO=
  run effective_crash_mode
  [ "$output" = "local" ]
}

@test "standalone + pr + ALLOW_PR_FOR_STANDALONE=1 stays pr" {
  SOURCE_MODE=standalone CRASH_MODE=pr ALLOW_PR_FOR_STANDALONE=1
  run effective_crash_mode
  [ "$output" = "pr" ]
}

@test "private stays private for standalone" {
  SOURCE_MODE=standalone CRASH_MODE=private CORPUS_REPO=git@github.com:keyorixhq/fuzz-corpus.git
  run effective_crash_mode
  [ "$output" = "private" ]
}

@test "private stays private for git" {
  SOURCE_MODE=git CRASH_MODE=private CORPUS_REPO=git@github.com:keyorixhq/fuzz-corpus.git
  run effective_crash_mode
  [ "$output" = "private" ]
}

@test "standalone + local stays local" {
  SOURCE_MODE=standalone CRASH_MODE=local
  run effective_crash_mode
  [ "$output" = "local" ]
}

@test "git + local stays local" {
  SOURCE_MODE=git CRASH_MODE=local
  run effective_crash_mode
  [ "$output" = "local" ]
}

@test "crash mode defaults to local when unset" {
  SOURCE_MODE=git
  run effective_crash_mode
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
