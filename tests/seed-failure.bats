#!/usr/bin/env bats
# seed_failure_message / report_nonrepro_exit: a fuzz target failing on its OWN seed corpus is a
# deterministic harness failure and must alert; a plain non-zero exit stays "infra/timeout".

setup() {
  FUZZ_RUNNER_LIB=1 source "${BATS_TEST_DIRNAME}/../fuzz-runner.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/logs"; STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$LOG_DIR" "$STATE_DIR"
  NOTES="$BATS_TEST_TMPDIR/notes"; : > "$NOTES"
  notify() { printf '%s\n' "$1" >> "$NOTES"; }
  SEED_SLICE=$'fuzz: elapsed: 0s, gathering baseline coverage: 0/6 completed\nfailure while testing seed corpus entry: FuzzX/seed#0\n--- FAIL: FuzzX (1.31s)\n        harness_test.go:547: EXEC ALLOWLIST: dsd attempted to execute "/usr/bin/vmware-toolbox-cmd"\nFAIL\n'
}

@test "seed failure in this slice is detected and the Go failure line extracted" {
  printf '%s' "$SEED_SLICE" > "$LOG_DIR/FuzzX.log"
  run seed_failure_message FuzzX 0
  [ "$status" -eq 0 ]
  [[ "$output" == harness_test.go:547:* ]]
}

@test "a seed-failure marker from an EARLIER rotation (before the offset) is ignored" {
  printf '%s' "$SEED_SLICE" > "$LOG_DIR/FuzzX.log"
  off=$(wc -c < "$LOG_DIR/FuzzX.log")
  printf 'fuzz: elapsed: 900s, execs: 1000\n' >> "$LOG_DIR/FuzzX.log"
  run seed_failure_message FuzzX "$off"
  [ "$status" -ne 0 ]
}

@test "ordinary non-zero exit stays logged-not-alerted" {
  printf 'fuzz: elapsed: 900s\nsignal: killed\n' > "$LOG_DIR/FuzzX.log"
  run report_nonrepro_exit FuzzX 1 0
  [[ "$output" == *"infra/timeout, logged not alerted"* ]]
  [ ! -s "$NOTES" ]
}

@test "seed failure alerts, and only once per target per day" {
  printf '%s' "$SEED_SLICE" > "$LOG_DIR/FuzzX.log"
  report_nonrepro_exit FuzzX 1 0 2>/dev/null
  report_nonrepro_exit FuzzX 1 0 2>/dev/null
  [ "$(wc -l < "$NOTES")" -eq 1 ]
  grep -q "HARNESS BROKEN: FuzzX" "$NOTES"
  grep -q "vmware-toolbox-cmd" "$NOTES"
  # a different target is not silenced by FuzzX's stamp
  printf '%s' "${SEED_SLICE//FuzzX/FuzzY}" > "$LOG_DIR/FuzzY.log"
  report_nonrepro_exit FuzzY 1 0 2>/dev/null
  [ "$(wc -l < "$NOTES")" -eq 2 ]
}
