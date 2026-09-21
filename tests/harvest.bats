#!/usr/bin/env bats
# harvest-crashers.sh end to end: a real checkout with a tracked seed and an untracked
# failing input, a slice log naming it, and a local bare repo standing in for fuzz-corpus.

H="${BATS_TEST_DIRNAME}/../harvest-crashers.sh"

gitq() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

setup() {
  T="$(mktemp -d)"; export HOME="$T/home"; mkdir -p "$HOME"
  export HARVEST_ROOTS="$HOME" HARVEST_STATE="$T/state" HARVEST_HOST=testrig
  export HARVEST_ALERT_MIN=30 HARVEST_STALE_MIN=20

  gitq init -q --bare "$T/corpus.git"
  gitq clone -q "$T/corpus.git" "$T/seed" 2>/dev/null
  mkdir -p "$T/seed/crashers" && touch "$T/seed/crashers/.gitkeep" && echo private > "$T/seed/README.md"
  gitq -C "$T/seed" add -A && gitq -C "$T/seed" commit -qm init && gitq -C "$T/seed" push -q origin HEAD:main
  export CORPUS_REPO="file://$T/corpus.git"

  R="$HOME/work/widget"; P="$R/internal/foo/testdata/fuzz/FuzzX"
  mkdir -p "$P"; echo "module example.com/acme/widget" > "$R/go.mod"
  printf 'go test fuzz v1\n[]byte("seed")\n' > "$P/seed0001"
  gitq init -q "$R" && gitq -C "$R" add -A && gitq -C "$R" commit -qm init
  printf 'go test fuzz v1\n[]byte("boom")\n' > "$P/abc123"

  mkdir -p "$HOME/night/logs"
  { echo "fuzz: elapsed: 3s"; echo "--- FAIL: FuzzX (3.00s)"; echo "    x_test.go:9: BYPASS: boom";
    echo "    Failing input written to testdata/fuzz/FuzzX/abc123"; } > "$HOME/night/logs/S1-FuzzX-0100.log"
  echo "unrelated" > "$HOME/night/logs/other.log"

  B="widget/example.com_acme_widget_internal_foo/FuzzX/abc123"
}

teardown() { rm -rf "$T"; }

remote_has() { git --git-dir="$T/corpus.git" cat-file -e "main:crashers/$1" 2>/dev/null; }
remote_commits() { git --git-dir="$T/corpus.git" rev-list --count main; }

@test "dry-run lists the untracked failing input, not the tracked seed, and writes nothing to the repo" {
  run "$H" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW    $B"* ]]
  [[ "$output" != *seed0001* ]]
  [ "$(remote_commits)" -eq 1 ]
}

@test "tick pushes input, meta and the naming log; bundle moves spool -> archive" {
  run "$H"
  [ "$status" -eq 0 ]
  remote_has "$B/abc123"
  remote_has "$B/meta.txt"
  remote_has "$B/logs/S1-FuzzX-0100.log"
  ! remote_has "$B/logs/other.log"
  git --git-dir="$T/corpus.git" show "main:crashers/$B/meta.txt" | grep -q 'BYPASS: boom'
  git --git-dir="$T/corpus.git" log -1 --format=%B main | grep -q 'Signed-off-by'
  [ -d "$HARVEST_STATE/archive/$B" ]
  [ ! -d "$HARVEST_STATE/spool/$B" ]
}

@test "second tick is a no-op (no new commit)" {
  "$H"; c1=$(remote_commits)
  "$H"; [ "$(remote_commits)" -eq "$c1" ]
}

@test "unreachable repo: input stays spooled, and --check alerts once past ALERT_MIN" {
  CORPUS_REPO="file://$T/nope.git" run "$H"
  [ "$status" -ne 0 ]
  [ -f "$HARVEST_STATE/spool/$B/abc123" ]
  HARVEST_ALERT_MIN=0 run "$H" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"unpushed"*"$B"* ]]
}

@test "spooled input is pushed on the next tick once the repo is back" {
  CORPUS_REPO="file://$T/nope.git" "$H" || true
  run "$H"
  [ "$status" -eq 0 ]
  remote_has "$B/abc123"
}

@test "--check is OK after a successful tick" {
  "$H"
  run "$H" --check
  [ "$status" -eq 0 ]
  [[ "$output" == OK*"pushed=1 pending=0"* ]]
}

@test "--check alerts on a failing input that appeared after the last tick" {
  "$H"
  printf 'go test fuzz v1\n[]byte("late")\n' > "$HOME/work/widget/internal/foo/testdata/fuzz/FuzzX/def456"
  run "$H" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"not harvested"*def456* ]]
}

@test "--check alerts when the harvester has never run" {
  run "$H" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"never completed a scan"* ]]
}

@test "--check alerts when the last scan is stale (cron dead)" {
  "$H"
  echo "last_scan_epoch=$(( $(date +%s) - 3600 ))" > "$HARVEST_STATE/status"
  run "$H" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"not running"* ]]
}

@test "a git-ignored failing input is still harvested" {
  echo "testdata/" > "$HOME/work/widget/.gitignore"
  run "$H" --dry-run
  [[ "$output" == *"NEW    $B"* ]]
}

@test "inputs inside build/module caches are ignored" {
  C="$HOME/night/gocache/x"; mkdir -p "$C/testdata/fuzz/FuzzY"
  git init -q "$C"; echo x > "$C/testdata/fuzz/FuzzY/zzz"
  run "$H" --dry-run
  [[ "$output" != *FuzzY* ]]
}

@test "a second rig harvesting the same input does not duplicate or conflict" {
  "$H"; c1=$(remote_commits)
  HARVEST_STATE="$T/state2" HARVEST_HOST=rig2 run "$H"
  [ "$status" -eq 0 ]
  remote_has "$B/abc123"
  [ "$(remote_commits)" -ge "$c1" ]
}

@test "HARVEST_EXCLUDE dirs (mutation-testing corpus copies) are not harvested" {
  M="$HOME/mut-work/widget-mut"; mkdir -p "$M/pkg/testdata/fuzz/FuzzM"
  git init -q "$M"; echo x > "$M/pkg/testdata/fuzz/FuzzM/corpus1"
  run "$H" --dry-run
  [[ "$output" != *FuzzM* ]]
  [[ "$output" == *"NEW    $B"* ]]
}

@test "a scan with more than HARVEST_MAX_NEW new inputs is refused: nothing pushed, --check alerts" {
  HARVEST_MAX_NEW=0 run "$H"
  [ "$(remote_commits)" -eq 1 ]
  [ ! -d "$HARVEST_STATE/spool/$B" ]
  run "$H" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *REFUSED* ]]
}

@test "the same input in two checkouts (a replay copy) is one bundle" {
  C="$HOME/replay"; mkdir -p "$C/internal/foo/testdata/fuzz/FuzzX"
  echo "module example.com/acme/widget" > "$C/go.mod"; git init -q "$C"
  cp "$HOME/work/widget/internal/foo/testdata/fuzz/FuzzX/abc123" "$C/internal/foo/testdata/fuzz/FuzzX/"
  run "$H" --dry-run
  [[ "$output" == *"-- 1 new input(s)"* ]]
}
