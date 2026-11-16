#!/usr/bin/env bats
# Red-proof for crasher-pull.sh / crasher-watch.sh: every control tested in crasher-pull.bats
# is shown RED against a COPY of the script with exactly that guard removed (the line
# carries a "# GUARD:<name>" marker). The scenario must fail at the EXPECTED check, not
# merely fail. The production files are never edited; mutants live under $T/mut and die
# with the test. If someone renames a guard marker, "mutant differs" fails: the proof
# cannot silently turn vacuous.

load helpers/crasher-pull-lib

setup()    { cp_setup; }
teardown() { cp_teardown; }

# mutant <script> <name> <sed args...>: copy with one guard removed; prints its path
mutant() {
  local src="$1" name="$2"; shift 2
  sed "$@" "$src" > "$T/mut/$name"; chmod +x "$T/mut/$name"
  if cmp -s "$src" "$T/mut/$name"; then echo "mutant differs from the original: NO (guard marker/pattern not found)" >&3; return 1; fi
  echo "$T/mut/$name"
}
# red <expected-failed-check regex> <scenario...>: the scenario must FAIL, at that check
red() {
  local want="$1"; shift
  SC_WHY=""
  if "$@"; then echo "STILL GREEN against the mutant: the guard is not proven" >&3; return 1; fi
  echo "red (guard removed) -> failed check: ${SC_WHY}" >&3
  [[ "$SC_WHY" =~ $want ]]
}

@test "red: no hash verification -> a corrupted copy would be accepted and the host copy deleted" {
  PULL=$(mutant "$REPO/crasher-pull.sh" crasher-pull.sh -E '/GUARD:hash-verify/s/if \[ -z "\$got" \] \|\| \[ "\$got" != "\$want" \]; then/if false; then/')
  red 'host copy still there' sc_hash_mismatch
}
@test "red: copy exit status ignored -> a copy that exited non-zero would still lead to a delete" {
  PULL=$(mutant "$REPO/crasher-pull.sh" crasher-pull.sh -E '/GUARD:copy-ok/s/if ! (copy_from_host[^;]*); then/\1; if false; then/')
  red 'host copy still there' sc_late_interrupt
}
@test "red: neither copy status nor hash checked -> an interrupted copy (files missing) is accepted and the host copy deleted" {
  PULL=$(mutant "$REPO/crasher-pull.sh" crasher-pull.sh -E -e '/GUARD:hash-verify/s/if \[ -z "\$got" \] \|\| \[ "\$got" != "\$want" \]; then/if false; then/' -e '/GUARD:copy-ok/s/if ! (copy_from_host[^;]*); then/\1; if false; then/')
  red 'host copy still there' sc_partial_copy
}
@test "red: delete without re-verifying on the host -> a file that arrived after the copy is destroyed" {
  PULL=$(mutant "$REPO/crasher-pull.sh" crasher-pull.sh -E 's/\[ "\$h" = "\$2" \] \|\| exit 7\\n//')
  red 'late file|survives' sc_host_changes_before_delete
}
@test "red: no name validation -> a hostile directory name is executed on the host side" {
  PULL=$(mutant "$REPO/crasher-pull.sh" crasher-pull.sh -E '/GUARD:name-validate/s/if .*; then #/if false; then #/')
  red 'nothing (pulled|executed)|no copy|no delete' sc_hostile_listing
}
@test "red: dry-run guard removed -> --dry-run would copy and delete" {
  PULL=$(mutant "$REPO/crasher-pull.sh" crasher-pull.sh -E '/GUARD:dry-run/s/\[ "\$DRY" = 1 \]/false/')
  red 'says what|host copy intact|no copy|no delete|no state' sc_dry_run
}
@test "red: trigger text reaches a shell -> an issue title executes (spoofed trigger)" {
  cat > "$T/m.sed" <<'EOS'
/GUARD:trigger-no-args/c\
  eval "$CW_PULL $(jq -r '.[0].title' "$CW_STATE/last.body")"
EOS
  WATCH=$(mutant "$REPO/crasher-watch.sh" crasher-watch.sh -f "$T/m.sed")
  red 'no injected command ran|zero arguments' sc_spoofed_trigger_has_no_args
}
@test "red: comments ignored in the issue digest -> a new comment on an existing issue triggers nothing" {
  WATCH=$(mutant "$REPO/crasher-watch.sh" crasher-watch.sh -E '/GUARD:comments-count/s/ \\\(\.updated_at\) \\\(\.comments\)//')
  red 'new comment triggers' sc_comment_triggers_a_pass
}
@test "red: schedule without StartInterval -> a missed event has no fallback" {
  cp "$REPO/deploy/mac/com.keyorix.crasher-pull.plist" "$T/mut/no-interval.plist"
  plutil -remove StartInterval "$T/mut/no-interval.plist"
  red 'every <= 10 min' sc_schedule_plist "$T/mut/no-interval.plist"
}
@test "red: schedule without RunAtLoad -> a Mac that slept through the login has no first pass" {
  cp "$REPO/deploy/mac/com.keyorix.crasher-pull.plist" "$T/mut/no-load.plist"
  plutil -replace RunAtLoad -bool NO "$T/mut/no-load.plist"
  red 'login' sc_schedule_plist "$T/mut/no-load.plist"
}
