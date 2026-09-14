#!/usr/bin/env bats
# Tests for deploy/deploy.sh — the rig registry, arg handling, and --dry-run
# plans. deploy.sh returns before main() when DEPLOY_LIB is set, so we can source
# it to test the pure registry helpers without touching a rig. The --dry-run
# tests run the script for real but it makes no ssh/scp calls in that mode.

ROOT="${BATS_TEST_DIRNAME}/.."
DEPLOY="$ROOT/deploy/deploy.sh"

# --- registry (sourced, no main) --------------------------------------------

@test "rig_rec: every listed rig resolves; unknown does not" {
  DEPLOY_LIB=1 source "$DEPLOY"
  for r in keyorix dashdiag libs-extra libs; do
    run rig_rec "$r"; [ "$status" -eq 0 ]
  done
  run rig_rec bogus; [ "$status" -ne 0 ]
}

@test "rig_field: service names match the canonical unit files" {
  DEPLOY_LIB=1 source "$DEPLOY"
  [ "$(rig_field keyorix 4)" = keyorix-fuzz ]
  [ "$(rig_field dashdiag 4)" = dashdiag-fuzz ]
  [ "$(rig_field libs-extra 4)" = libs-extra-fuzz ]
  [ "$(rig_field libs 4)" = libsfuzz ]
}

@test "rig_field: libs-extra runs the SHARED runner copy (not a private one)" {
  DEPLOY_LIB=1 source "$DEPLOY"
  # The libs-extra unit's ExecStart is the shared fuzz-harness runner; the
  # registry must point deploy at that path, not ~/proj/libs-extra-fuzz.
  [ "$(rig_field libs-extra 2)" = /home/andrei/proj/fuzz-harness/fuzz-runner.sh ]
  [ "$(rig_field dashdiag 2)" = "$(rig_field libs-extra 2)" ]
}

@test "rig_field: source_mode is git for own-code rigs, standalone otherwise" {
  DEPLOY_LIB=1 source "$DEPLOY"
  [ "$(rig_field keyorix 5)" = git ]
  [ "$(rig_field dashdiag 5)" = git ]
  [ "$(rig_field libs-extra 5)" = standalone ]
  [ "$(rig_field libs 5)" = standalone ]
}

@test "every rig's service has a tracked canonical unit file" {
  DEPLOY_LIB=1 source "$DEPLOY"
  for r in keyorix dashdiag libs-extra libs; do
    svc="$(rig_field "$r" 4)"
    [ -f "$ROOT/deploy/systemd/$svc.service" ]
  done
}

# --- arg handling ------------------------------------------------------------

@test "--list prints exactly the four rig keys" {
  run bash "$DEPLOY" --list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = keyorix ]
  [ "${lines[1]}" = dashdiag ]
  [ "${lines[2]}" = libs-extra ]
  [ "${lines[3]}" = libs ]
}

@test "unknown rig aborts with non-zero (deploy mode)" {
  run bash "$DEPLOY" --dry-run bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown rig 'bogus'"* ]]
}

@test "unknown rig aborts with non-zero (unit mode) — subshell die bug guard" {
  run bash "$DEPLOY" --dry-run --unit bogus
  [ "$status" -ne 0 ]
  [[ "$output" != *"0 rig(s)"* ]]
}

@test "--bootstrap takes exactly one rig" {
  run bash "$DEPLOY" --dry-run --bootstrap keyorix dashdiag
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one rig"* ]]
}

# --- dry-run plans (no ssh/scp happen) --------------------------------------

@test "dry-run deploy shows the shared runner path for libs-extra" {
  run bash "$DEPLOY" --dry-run libs-extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"vcd-dashdiag-fuzz:/home/andrei/proj/fuzz-harness"* ]]
  [[ "$output" == *"bump reload marker in /home/andrei/proj/libs-extra-fuzz/fuzz.conf"* ]]
}

@test "dry-run unit plan names the canonical unit and sudo install" {
  run bash "$DEPLOY" --dry-run --unit keyorix
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy/systemd/keyorix-fuzz.service"* ]]
  [[ "$output" == *"/etc/systemd/system/keyorix-fuzz.service"* ]]
}

@test "dry-run bootstrap (git rig) plans a module clone + seed + enable" {
  run bash "$DEPLOY" --dry-run --bootstrap dashdiag
  [ "$status" -eq 0 ]
  [[ "$output" == *"git clone https://github.com/keyorixhq/dashdiag.git"* ]]
  [[ "$output" == *"enable --now dashdiag-fuzz"* ]]
  [[ "$output" == *"no changes made"* ]]
}

@test "dry-run bootstrap (standalone rig) says assemble-by-hand, no clone" {
  run bash "$DEPLOY" --dry-run --bootstrap libs
  [ "$status" -eq 0 ]
  [[ "$output" == *"STANDALONE"* ]]
  [[ "$output" != *"git clone"* ]]
}

# --- starter template keeps the fleet baseline ------------------------------

@test "starter template carries the shared fleet-baseline lines" {
  tmpl="$ROOT/templates/fuzz-rig.service.tmpl"
  [ -f "$tmpl" ]
  grep -q '^Type=simple' "$tmpl"
  grep -q '^After=network-online.target' "$tmpl"
  grep -q '^MemorySwapMax=0' "$tmpl"
  grep -q '^WantedBy=multi-user.target' "$tmpl"
  # It is a STARTER, not a renderer for the live rigs — it must say so.
  grep -qi 'starting point\|starter' "$tmpl"
}
