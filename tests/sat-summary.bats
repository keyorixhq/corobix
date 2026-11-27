#!/usr/bin/env bats
# sat-summary.sh: verdict per target (saturated / active / young) and the top-N list.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/sat-summary.sh"
  F="$BATS_TEST_TMPDIR/sat.txt"
  printf 'A 5 0 0\nB 3 7 40\nC 1 9 9\nD 4 300 900\nE 3 12 12\n' > "$F"
}

@test "counts saturated, active and young targets" {
  run env SAT_FILE="$F" "$SCRIPT" -t 0 r1
  [ "$status" -eq 0 ]
  [[ "$output" == *"targets=5"*"saturated=1"*"active=3"*"young(<3 runs)=1"* ]]
}

@test "lists the most active targets, highest first" {
  run env SAT_FILE="$F" "$SCRIPT" -t 2 r1
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *"+300"*"D"* ]]
  [[ "${lines[2]}" == *"+12"*"E"* ]]
}

@test "CONFIRM_MIN_RUNS moves the young/judged boundary" {
  run env CONFIRM_MIN_RUNS=5 SAT_FILE="$F" "$SCRIPT" -t 0 r1
  [[ "$output" == *"saturated=1"*"active=0"*"young(<5 runs)=4"* ]]
}

@test "an unknown rig is refused" {
  run "$SCRIPT" nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown rig"* ]]
}
