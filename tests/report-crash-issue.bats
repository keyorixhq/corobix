#!/usr/bin/env bats
# report_crash_issue: an open issue with the same title gets a comment, a closed
# one gets a NEW issue that points back at it (a comment on a closed issue never
# shows up as open work; fuzz-corpus#179 / #188). gh is a stub that records calls.

setup() {
  FUZZ_RUNNER_LIB=1 source "${BATS_TEST_DIRNAME}/../fuzz-runner.sh"
  STUB="$BATS_TEST_TMPDIR/bin"; CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$STUB"; : > "$CALLS"
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
# list call: print $GH_LIST_OUT (what the --jq filter would have produced)
if [ "$1" = api ] && [ "$2" != "-X" ]; then printf '%s' "$GH_LIST_OUT"; exit 0; fi
printf '%s\n' "$*" >> "$GH_CALLS"
EOF
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH" GH_CALLS="$CALLS"
  log() { :; }
}

@test "no matching issue: creates a new issue" {
  GH_LIST_OUT="" report_crash_issue o/r "fuzz(crash): FuzzX" "BODY" "TS" 1 /dest
  run cat "$CALLS"
  [[ "$output" == *"-X POST repos/o/r/issues -f title=fuzz(crash): FuzzX"* ]]
  [[ "$output" != *"Regression of"* ]]
}

@test "open match: comments, creates nothing" {
  GH_LIST_OUT="179 open" report_crash_issue o/r "fuzz(crash): FuzzX" "BODY" "TS" 1 /dest
  run cat "$CALLS"
  [[ "$output" == *"repos/o/r/issues/179/comments"* ]]
  [[ "$output" == *"Seen again"* ]]
  [[ "$output" != *"-f title="* ]]
}

@test "closed match: opens a NEW issue that points back, no comment on the closed one" {
  GH_LIST_OUT="179 closed" report_crash_issue o/r "fuzz(crash): FuzzX" "BODY" "TS" 1 /dest
  run cat "$CALLS"
  [[ "$output" == *"-X POST repos/o/r/issues -f title=fuzz(crash): FuzzX"* ]]
  [[ "$output" == *"Regression of #179 (closed)"* ]]
  [[ "$output" != *"issues/179/comments"* ]]
}
