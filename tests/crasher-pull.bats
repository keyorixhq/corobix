#!/usr/bin/env bats
# crasher-pull.sh / crasher-watch.sh: the controls hold. Fake hosts (local dirs) behind
# ssh/rsync/curl shims; see helpers/crasher-pull-lib.bash for the scenarios. The same
# scenarios are shown RED against guard-less mutants in crasher-pull-redproof.bats.

load helpers/crasher-pull-lib

setup()    { cp_setup; }
teardown() { cp_teardown; }

holds() { "$@" || { echo "control failed: ${SC_WHY:-?}" >&3; echo "--- puller stderr"; cat "$T/err" 2>/dev/null; return 1; }; }

@test "normal pull: copied, hash verified, only then the host copy is deleted; ledger + third-party marker" {
  holds sc_normal
}
@test "hash mismatch (rsync says ok, bytes differ): nothing deleted on the host" {
  holds sc_hash_mismatch
}
@test "interrupted copy (files missing): nothing deleted on the host" {
  holds sc_partial_copy
}
@test "copy exits non-zero even though every byte arrived: still nothing deleted" {
  holds sc_late_interrupt
}
@test "host copy changes after the copy: the delete re-verifies on the host and refuses" {
  holds sc_host_changes_before_delete
}
@test "delete fails after a good pull: host copy stays, next pass deletes it without a second copy or ledger line" {
  holds sc_delete_failure_then_retry
}
@test "second run pulls nothing and changes nothing" {
  holds sc_second_run_pulls_nothing
}
@test "two crashers for one target (second = only a comment on the issue) are both pulled" {
  holds sc_two_crashers_one_target
}
@test "an unreachable host is skipped loudly; the others are still pulled" {
  holds sc_one_host_down
}
@test "dry-run changes nothing: no copy, no delete, no state, no quarantine" {
  holds sc_dry_run
}
@test "hostile listing from a compromised host: unsafe names never reach a path or a command" {
  holds sc_hostile_listing
}
@test "missed event: no trigger arrives, the plain scheduled run still pulls it" {
  holds sc_missed_event_schedule_pulls
}
@test "schedule: the shipped plist runs the puller at login and every <= 10 min" {
  holds sc_schedule_plist "$REPO/deploy/mac/com.keyorix.crasher-pull.plist"
}
@test "watcher plist is valid and keeps the watcher alive" {
  plutil -lint "$REPO/deploy/mac/com.keyorix.crasher-watch.plist"
  [ "$(plutil -extract KeepAlive raw "$REPO/deploy/mac/com.keyorix.crasher-watch.plist")" = true ]
}
@test "issue polling: new issue and new comment trigger a pass, a 304 and unrelated issues do not; token not in argv" {
  holds sc_comment_triggers_a_pass
}
@test "spoofed trigger: an issue naming a host, a path and a command changes nothing; only the fixed hosts are contacted" {
  holds sc_spoofed_issue_changes_nothing
}
@test "spoofed trigger: issue and ntfy text never reach the puller (zero arguments) or a shell" {
  holds sc_spoofed_trigger_has_no_args
}
@test "puller takes no host/path/command arguments" {
  run "$PULL" evil.example
  [ "$status" -eq 64 ]
  run "$PULL" --host evil.example
  [ "$status" -eq 64 ]
}
@test "hosts file with an option-injection destination is rejected" {
  printf -- '-oProxyCommand=touch PWNED_OPT -\nhost-a fakea -\n' > "$T/hosts.conf"
  mk fakea parser aaaaaaaa11
  run "$PULL"
  [ -d "$CP_QUARANTINE/host-a/parser/aaaaaaaa11" ]
  no_pwned
  [ "$status" -ne 0 ]   # the bad line is reported
}
@test "shipped hosts file lists only the two vCD fuzz hosts" {
  run grep -vE '^[[:space:]]*(#|$)' "$REPO/deploy/mac/crasher-pull.hosts"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == vcd-keyorix-fuzz* ]]
  [[ "${lines[1]}" == vcd-dashdiag-fuzz* ]]
}
