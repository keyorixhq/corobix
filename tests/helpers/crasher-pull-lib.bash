# Shared by tests/crasher-pull.bats (the controls hold) and tests/crasher-pull-redproof.bats
# (the same scenarios must FAIL against a copy of the script with one guard removed).
# A scenario returns 0 when the control holds; on failure it sets SC_WHY and returns 1.
# Fake hosts are directories under $FAKE_HOSTS/<ssh alias>; ssh/rsync/curl are shims, so no
# real host, network or credential is involved.

REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
PULL="${PULL:-$REPO/crasher-pull.sh}"
WATCH="${WATCH:-$REPO/crasher-watch.sh}"

need() { SC_WHY="$1"; shift; "$@"; }   # <description> <command...>; SC_WHY names the failed check
not() { ! "$@"; }

cp_setup() {
  T="$(mktemp -d)"; export T HOME="$T/home"
  mkdir -p "$HOME" "$T/bin" "$T/srv" "$T/mut"
  cd "$T" || return 1   # injected 'touch PWNED*' would land here, where the checks look
  export FAKE_HOSTS="$T/hosts"; mkdir -p "$FAKE_HOSTS/fakea" "$FAKE_HOSTS/fakeb"
  export CALLS="$T/calls.log"; : > "$CALLS"
  printf 'host-a fakea -\nhost-b fakeb -\n' > "$T/hosts.conf"
  printf '# third-party targets\nlibfoo\n' > "$T/third-party.conf"
  export CP_HOSTS_FILE="$T/hosts.conf" CP_THIRD_PARTY_FILE="$T/third-party.conf"
  export CP_STATE="$T/state" CP_QUARANTINE="$T/quar" CP_SSH="$T/bin/ssh" CP_RSYNC="$T/bin/rsync"
  export CW_STATE="$T/wstate" CW_TOKEN_FILE="$T/token" CW_NTFY_FILE="$T/ntfy-url" CW_CURL="$T/bin/curl" CW_PULL="$T/bin/pull-stub"
  echo 'ghp_FakeToken123' > "$CW_TOKEN_FILE"; echo 'https://ntfy.example/topic-x' > "$CW_NTFY_FILE"
  unset FAKE_RSYNC_MODE FAKE_SSH_DOWN FAKE_SSH_FAIL_DELETE

  cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# fake ssh: skip options, take the alias, run the remote command locally with HOME = the fake host
dest=""; while [ $# -gt 0 ]; do case "$1" in -o|-J|-p|-i) shift 2 ;; -*) shift ;; *) dest="$1"; shift; break ;; esac; done
cmd="$*"; in="$(mktemp)"; [ -t 0 ] || cat > "$in"
if [ ! -d "$FAKE_HOSTS/$dest" ] || [ "$FAKE_SSH_DOWN" = "$dest" ]; then echo "ssh $dest REFUSED" >> "$CALLS"; echo "ssh: cannot connect to $dest" >&2; exit 255; fi
if grep -q 'rm -rf' "$in"; then
  echo "ssh $dest DELETE" >> "$CALLS"; [ -z "$FAKE_SSH_FAIL_DELETE" ] || exit 255
else echo "ssh $dest $cmd" >> "$CALLS"; fi
HOME="$FAKE_HOSTS/$dest" sh -c "$cmd" < "$in"
EOF
  cat > "$T/bin/rsync" <<'EOF'
#!/usr/bin/env bash
# fake rsync: "<alias>:<path-under-home>/" -> local dir; failure modes via FAKE_RSYNC_MODE
args=("$@"); n=$#; src="${args[$((n-2))]}"; dst="${args[$((n-1))]}"
host="${src%%:*}"; rel="${src#*:}"; sd="$FAKE_HOSTS/$host/$rel"
echo "rsync $src" >> "$CALLS"
[ -d "$sd" ] || exit 23
case "${FAKE_RSYNC_MODE:-ok}" in
  ok)             cp -R "$sd." "$dst" ;;
  corrupt)        cp -R "$sd." "$dst"; f=$(find "$dst" -type f | sort | head -1); echo tampered >> "$f" ;;
  partial)        f=$(find "$sd" -type f | sort | head -1); cp "$f" "$dst/"; exit 30 ;;
  late-interrupt) cp -R "$sd." "$dst"; exit 30 ;;
  mutate-host)    cp -R "$sd." "$dst"; echo late > "$sd/late-arrival" ;;
esac
EOF
  cat > "$T/bin/pull-stub" <<'EOF'
#!/usr/bin/env bash
echo "pull argc=$#" >> "$T/pulls.log"
EOF
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# fake curl: GitHub issues list with ETag/If-None-Match from $T/srv/{etag,body.json}; ntfy stream from $T/srv/ntfy.stream
echo "curl $*" >> "$T/curl.log"
hf=""; of=""; inm=""; url=""
while [ $# -gt 0 ]; do case "$1" in
  -D) hf="$2"; shift 2 ;; -o) of="$2"; shift 2 ;; -w|-m|--config) shift 2 ;;
  -H) case "$2" in If-None-Match:*) inm="${2#If-None-Match: }" ;; esac; shift 2 ;;
  -*) shift ;; *) url="$1"; shift ;; esac; done
[ -t 0 ] || cat > /dev/null
case "$url" in */json) cat "$T/srv/ntfy.stream"; exit 0 ;; esac
et=$(cat "$T/srv/etag")
if [ "$inm" = "$et" ]; then printf 'HTTP/2 304\r\netag: %s\r\n' "$et" > "$hf"; : > "$of"; printf 304
else printf 'HTTP/2 200\r\nETag: %s\r\n' "$et" > "$hf"; cp "$T/srv/body.json" "$of"; printf 200; fi
EOF
  chmod +x "$T/bin/ssh" "$T/bin/rsync" "$T/bin/pull-stub" "$T/bin/curl"
}

cp_teardown() { rm -rf "$T"; }

# --- fixtures -----------------------------------------------------------------------
mk() { # <alias> <target> <hash>
  local d="$FAKE_HOSTS/$1/lane/crashers/$2/$3"; mkdir -p "$d/logs"
  printf 'go test fuzz v1\n[]byte("%s")\n' "$3" > "$d/input"; echo "meta $3" > "$d/meta.txt"; echo "log $3" > "$d/logs/run.log"
}
host_has() { [ -d "$FAKE_HOSTS/$1/lane/crashers/$2/$3" ]; }
# Fails when the puller did not complete a pass: without this, every "nothing was deleted"
# check would pass vacuously on a script that never ran (not executable, syntax error...).
run_pull() {
  PULL_RC=0; "$PULL" "$@" > "$T/out" 2> "$T/err" || PULL_RC=$?
  need "puller completed a pass (precondition)" grep -q 'pass done' "$T/err"
}
n_calls() { grep -c "$1" "$CALLS" 2>/dev/null || true; }
ledger_n() { awk -F'\t' -v s="$1" '$5==s' "$CP_LEDGER" 2>/dev/null | wc -l | tr -d ' '; }
export_ledger() { export CP_LEDGER="$CP_STATE/ledger.tsv"; }
nothing_deleted() { [ "$(n_calls DELETE)" = 0 ]; }
no_pwned() { [ -z "$(find "$T" -name 'PWNED*' -print -quit)" ]; }

# --- puller scenarios -----------------------------------------------------------------
sc_normal() {
  export_ledger
  mk fakea libfoo aaaaaaaa11; mk fakeb parser bbbbbbbb22
  cp -R "$FAKE_HOSTS/fakea/lane/crashers/libfoo/aaaaaaaa11" "$T/expect-a"
  run_pull || return 1
  need "exit 0" [ "$PULL_RC" = 0 ] || return 1
  need "host-a copy deleted" not host_has fakea libfoo aaaaaaaa11 || return 1
  need "host-b copy deleted" not host_has fakeb parser bbbbbbbb22 || return 1
  need "quarantine copy identical" diff -r "$T/expect-a" "$CP_QUARANTINE/host-a/libfoo/aaaaaaaa11" || return 1
  need "third-party marker" [ -f "$CP_QUARANTINE/host-a/libfoo/aaaaaaaa11.DO-NOT-PUBLISH" ] || return 1
  need "no marker on a first-party target" [ ! -e "$CP_QUARANTINE/host-b/parser/bbbbbbbb22.DO-NOT-PUBLISH" ] || return 1
  need "ledger: 2 pulled-ok" [ "$(ledger_n pulled-ok)" = 2 ] || return 1
  need "ledger: third-party flag" grep -q "host-a.libfoo.aaaaaaaa11.pulled-ok.third-party" "$CP_LEDGER" || return 1
  # the host delete came strictly after the copy
  local r d; r=$(grep -n '^rsync' "$CALLS" | head -1 | cut -d: -f1); d=$(grep -n 'DELETE' "$CALLS" | head -1 | cut -d: -f1)
  need "delete after copy" [ -n "$r" ] && [ -n "$d" ] && [ "$r" -lt "$d" ] || return 1
}

# the host copy must survive a failed/bad copy: nothing deleted, nothing kept as pulled
sc_copy_fails_leaves_host() { # <rsync mode>
  export_ledger; mk fakea parser cccccccc33
  export FAKE_RSYNC_MODE="$1"; run_pull || return 1
  need "host copy still there" host_has fakea parser cccccccc33 || return 1
  need "no delete command was sent" nothing_deleted || return 1
  need "nothing in quarantine" [ ! -e "$CP_QUARANTINE/host-a/parser/cccccccc33" ] || return 1
  need "no pulled-ok in ledger" [ "$(ledger_n pulled-ok)" = 0 ] || return 1
  need "non-zero exit" [ "$PULL_RC" != 0 ] || return 1
}
sc_hash_mismatch()  { sc_copy_fails_leaves_host corrupt; }          # rsync says OK, bytes differ
sc_partial_copy()   { sc_copy_fails_leaves_host partial; }          # interrupted, files missing
sc_late_interrupt() { sc_copy_fails_leaves_host late-interrupt; }   # all bytes arrived but rsync failed

sc_host_changes_before_delete() {
  export_ledger; mk fakea parser dddddddd44
  export FAKE_RSYNC_MODE=mutate-host; run_pull || return 1
  need "host copy (with the late file) survives" [ -f "$FAKE_HOSTS/fakea/lane/crashers/parser/dddddddd44/late-arrival" ] || return 1
  need "never reported host-deleted" [ "$(ledger_n host-deleted)" = 0 ] || return 1
  need "non-zero exit" [ "$PULL_RC" != 0 ] || return 1
}

sc_delete_failure_then_retry() {
  export_ledger; mk fakea parser eeeeeeee55
  export FAKE_SSH_FAIL_DELETE=1; run_pull || return 1
  need "host copy stays when delete fails" host_has fakea parser eeeeeeee55 || return 1
  need "pulled copy is in quarantine" [ -d "$CP_QUARANTINE/host-a/parser/eeeeeeee55" ] || return 1
  need "non-zero exit" [ "$PULL_RC" != 0 ] || return 1
  unset FAKE_SSH_FAIL_DELETE; run_pull || return 1
  need "second pass deletes it" not host_has fakea parser eeeeeeee55 || return 1
  need "one pulled-ok only" [ "$(ledger_n pulled-ok)" = 1 ] || return 1
  need "one host-deleted" [ "$(ledger_n host-deleted)" = 1 ] || return 1
  need "copied once" [ "$(n_calls '^rsync')" = 1 ] || return 1
}

sc_second_run_pulls_nothing() {
  export_ledger; mk fakea libfoo aaaaaaaa11
  run_pull || return 1; need "first run ok" [ "$PULL_RC" = 0 ] || return 1
  local r l; r=$(n_calls '^rsync'); l=$(wc -l < "$CP_LEDGER")
  run_pull || return 1
  need "second run exit 0" [ "$PULL_RC" = 0 ] || return 1
  need "no new copy" [ "$(n_calls '^rsync')" = "$r" ] || return 1
  need "ledger unchanged" [ "$(wc -l < "$CP_LEDGER")" = "$l" ] || return 1
}

sc_two_crashers_one_target() {  # the 2nd one is "only a comment" on the issue; both must be pulled
  export_ledger; mk fakea libfoo 11111111aa; mk fakea libfoo 22222222bb
  run_pull || return 1
  need "exit 0" [ "$PULL_RC" = 0 ] || return 1
  need "both in quarantine" [ -d "$CP_QUARANTINE/host-a/libfoo/11111111aa" ] && [ -d "$CP_QUARANTINE/host-a/libfoo/22222222bb" ] || return 1
  need "both gone from host" not host_has fakea libfoo 11111111aa && not host_has fakea libfoo 22222222bb || return 1
  need "two ledger lines" [ "$(ledger_n pulled-ok)" = 2 ] || return 1
}

sc_one_host_down() {
  export_ledger; mk fakea parser aaaaaaaa11; mk fakeb parser bbbbbbbb22
  export FAKE_SSH_DOWN=fakea; run_pull || return 1
  need "reachable host pulled" [ -d "$CP_QUARANTINE/host-b/parser/bbbbbbbb22" ] || return 1
  need "unreachable host untouched" host_has fakea parser aaaaaaaa11 || return 1
  need "non-zero exit" [ "$PULL_RC" != 0 ] || return 1
}

sc_dry_run() {
  export_ledger; mk fakea libfoo aaaaaaaa11
  run_pull --dry-run || return 1
  need "exit 0" [ "$PULL_RC" = 0 ] || return 1
  need "says what it would do" grep -q 'DRY-RUN host-a libfoo/aaaaaaaa11' "$T/err" || return 1
  need "host copy intact" host_has fakea libfoo aaaaaaaa11 || return 1
  need "no copy" [ "$(n_calls '^rsync')" = 0 ] || return 1
  need "no delete" nothing_deleted || return 1
  need "no state dir" [ ! -e "$CP_STATE" ] || return 1
  need "no quarantine dir" [ ! -e "$CP_QUARANTINE" ] || return 1
}

# a compromised host lists names that are not <plain target>/<hex hash>: they must never
# reach a path or a command line
sc_hostile_listing() {
  export_ledger
  local base="$FAKE_HOSTS/fakea/lane/crashers"
  mkdir -p "$base/a b/aaaaaaaa11" "$base/.hidden/aaaaaaaa11" "$base/parser/ZZZZZZZZ" "$base/parser/\$(touch PWNED_HOST)" "$base/parser/ab" "$base/lib;touch PWNED_SEMI/aaaaaaaa11"
  run_pull || return 1
  need "nothing pulled" [ -z "$(find "$CP_QUARANTINE" -mindepth 2 -print -quit 2>/dev/null)" ] || return 1
  need "nothing executed" no_pwned || return 1
  need "no copy attempted" [ "$(n_calls '^rsync')" = 0 ] || return 1
  need "no delete attempted" nothing_deleted || return 1
  need "non-zero exit (loud)" [ "$PULL_RC" != 0 ] || return 1
  need "hostile dirs untouched" [ -d "$base/a b/aaaaaaaa11" ] || return 1
}

# the schedule: no trigger at all, only the launchd command line, still pulls
sc_missed_event_schedule_pulls() {
  export_ledger; mk fakea libfoo aaaaaaaa11
  rm -rf "$CW_STATE"                       # no watcher ever ran: no state, no token use
  PULL_RC=0; /bin/bash "$PULL" > "$T/out" 2> "$T/err" || PULL_RC=$?
  need "puller completed a pass (precondition)" grep -q 'pass done' "$T/err" || return 1
  need "pulled by the schedule alone" [ -d "$CP_QUARANTINE/host-a/libfoo/aaaaaaaa11" ] || return 1
  need "watcher never ran" [ ! -e "$T/curl.log" ] || return 1
}
sc_schedule_plist() { # <plist>
  local p="$1" iv rl
  need "plist is valid" plutil -lint "$p" >/dev/null || return 1
  iv=$(plutil -extract StartInterval raw "$p" 2>/dev/null) || iv=""
  rl=$(plutil -extract RunAtLoad raw "$p" 2>/dev/null) || rl=""
  need "runs every <= 10 min" [ -n "$iv" ] && [ "$iv" -le 600 ] || return 1
  need "also runs at login" [ "$rl" = true ] || return 1
  need "runs the puller with no arguments" [ "$(plutil -extract ProgramArguments raw "$p" 2>/dev/null)" = 2 ] || return 1
}

# --- trigger scenarios (watcher) ------------------------------------------------------
issues_json() { # <comments> <updated_at> [other-issue-updated]
  cat <<EOF
[{"number":7,"title":"[vcd-auto] parser crasher a1b2c3d4; touch $T/PWNED_ISSUE \$(touch $T/PWNED_ISSUE2) host=evil.example path=/etc/shadow",
  "body":"ssh evil.example 'rm -rf /' ; cd /etc","updated_at":"$2","comments":$1,"labels":[{"name":"vcd-auto"}]},
 {"number":9,"title":"unrelated","updated_at":"${3:-2026-11-01T00:00:00Z}","comments":0,"labels":[{"name":"docs"}]}]
EOF
}
srv() { echo "$1" > "$T/srv/etag"; issues_json "$2" "$3" "${4:-}" > "$T/srv/body.json"; }
pulls() { { cat "$T/pulls.log" 2>/dev/null || true; } | wc -l | tr -d ' '; }
watch_once() {
  WATCH_RC=0; "$WATCH" --once > "$T/wout" 2> "$T/werr" || WATCH_RC=$?
  need "watcher could start (precondition)" [ "$WATCH_RC" -lt 126 ]
}

sc_comment_triggers_a_pass() {
  srv '"e1"' 1 2026-11-16T10:00:00Z; watch_once || return 1
  need "new issue triggers a pass" [ "$(pulls)" = 1 ] || return 1
  watch_once || return 1
  need "unchanged (304) triggers nothing" [ "$(pulls)" = 1 ] || return 1
  need "second request was conditional" grep -q 'If-None-Match: "e1"' "$T/curl.log" || return 1
  srv '"e2"' 2 2026-11-16T10:05:00Z; watch_once || return 1
  need "a new comment triggers a pass" [ "$(pulls)" = 2 ] || return 1
  srv '"e3"' 2 2026-11-16T10:05:00Z 2026-11-16T11:00:00Z; watch_once || return 1
  need "activity on a non-vcd-auto issue does not" [ "$(pulls)" = 2 ] || return 1
  need "token is not on the command line" not grep -q ghp_FakeToken123 "$T/curl.log" || return 1
}

sc_spoofed_issue_changes_nothing() {
  export_ledger; mk fakea libfoo aaaaaaaa11
  export CW_PULL="$PULL"
  srv '"e1"' 1 2026-11-16T10:00:00Z; watch_once || return 1
  need "no injected command ran" no_pwned || return 1
  need "puller still ran (it is only told to run)" [ -d "$CP_QUARANTINE/host-a/libfoo/aaaaaaaa11" ] || return 1
  need "only the fixed hosts were contacted" [ -z "$(grep -E '^ssh ' "$CALLS" | grep -vE '^ssh (fakea|fakeb) ' || true)" ] || return 1
  need "evil host never contacted" not grep -q evil "$CALLS" || return 1
  need "watcher exit 0" [ "$WATCH_RC" = 0 ] || return 1
}
sc_spoofed_trigger_has_no_args() {
  srv '"e1"' 1 2026-11-16T10:00:00Z; watch_once || return 1
  need "no injected command ran (issue)" no_pwned || return 1
  need "puller called with zero arguments (issue)" [ "$(cat "$T/pulls.log")" = "pull argc=0" ] || return 1
  rm -f "$T/pulls.log"
  printf '%s\n' '{"event":"open"}' \
    "{\"event\":\"message\",\"message\":\"; touch $T/PWNED_NTFY1 \$(touch $T/PWNED_NTFY2) ssh evil.example\"}" > "$T/srv/ntfy.stream"
  CW_NTFY_ONESHOT=1 "$WATCH" --ntfy > "$T/wout" 2> "$T/werr" || true
  need "no injected command ran (ntfy)" no_pwned || return 1
  need "ntfy message ran one pass, zero arguments" [ "$(cat "$T/pulls.log")" = "pull argc=0" ] || return 1
}
