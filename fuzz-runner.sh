#!/usr/bin/env bash
# fuzz-runner.sh — universal continuous-fuzz rotation runner (native go test -fuzz).
# Config: fuzz.conf beside this script, or $FUZZ_CONF. See README.md and the
# Keyorix project doc claude/2026-09-13-universal-fuzz-harness-spec.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()   { echo "[$(date -u +%FT%TZ)] $*" | tee -a "${LOG_DIR:-/tmp}/rotation.log" >&2; }
notify(){ [ -n "${NOTIFY_URL:-}" ] && curl -fsS -m 10 -d "$1" "$NOTIFY_URL" >/dev/null 2>&1 || true; }

# dur_to_secs <godur> -> integer seconds for an h/m/s go-duration ("1h30m","15m",
# "90s") or a bare integer (already seconds). Unparseable -> 0. (go test -fuzztime
# durations only ever use h/m/s here.)
dur_to_secs() {
  local s="$1" total=0 n
  [[ "$s" =~ ^[0-9]+$ ]] && { echo "$s"; return; }
  n="$(printf '%s' "$s" | grep -oE '[0-9]+h' | grep -oE '[0-9]+')"; [ -n "$n" ] && total=$(( total + n*3600 ))
  n="$(printf '%s' "$s" | grep -oE '[0-9]+m' | grep -oE '[0-9]+')"; [ -n "$n" ] && total=$(( total + n*60 ))
  n="$(printf '%s' "$s" | grep -oE '[0-9]+s' | grep -oE '[0-9]+')"; [ -n "$n" ] && total=$(( total + n ))
  echo "$total"
}

# is_saturated <fn> -> true iff >= CONFIRM_MIN_RUNS recorded runs with zero total
# new-coverage growth across the window (mirrors sat_verdict's SATURATED verdict,
# reading the same $STATE_DIR/sat/<fn> history record_saturation writes).
is_saturated() {
  local f="$STATE_DIR/sat/$1" n=0 s=0
  [ -r "$f" ] || return 1
  n="$(awk 'END{print NR+0}' "$f")"; s="$(awk '{t+=$1} END{print t+0}' "$f")"
  [ "$n" -ge "${CONFIRM_MIN_RUNS:-3}" ] && [ "$s" -eq 0 ]
}

# measured_exec_rate <fn> -> execs/sec from the target's last run (its last NON-zero
# "(K/sec)" tick; the very last tick prints 0/sec, so zeros are skipped), or 0 if
# unknown. The per-target log is append-only, so tail-most is the latest run.
measured_exec_rate() {
  local r
  r="$(grep -aoE '\([0-9]+/sec\)' "$LOG_DIR/$1.log" 2>/dev/null | grep -oE '[0-9]+' | grep -vxE '0' | tail -1)"
  echo "${r:-0}"
}

# measured_warmup_secs <fn> -> seconds Go spent gathering baseline coverage on the
# last run (the "elapsed: Xs, gathering baseline coverage: N/N completed, now
# fuzzing" line — the corpus-replay warm-up that a slice must dwarf), or 0.
measured_warmup_secs() {
  local e
  e="$(grep -aoE 'elapsed: [0-9hms]+, gathering baseline coverage: [0-9]+/[0-9]+ completed, now fuzzing' "$LOG_DIR/$1.log" 2>/dev/null | tail -1 | grep -oE 'elapsed: [0-9hms]+' | grep -oE '[0-9hms]+$')"
  if [ -n "$e" ]; then dur_to_secs "$e"; else echo 0; fi
}

# resolve_duration <FuzzFunc> -> the fuzztime for the next slice.
#
# Baseline (and the default when REWEIGHT_CONFIRM is off): the per-target override
# DURATION_<fn>, else DEFAULT_FUZZTIME. That is the ACTIVE / new-target budget, kept
# in full while a target is still finding coverage.
#
# With REWEIGHT_CONFIRM=on, once a target has gone SATURATED (is_saturated), its
# slice shrinks to a CONFIRMATION slice sized from that target's OWN throughput:
#   confirm = max( CONFIRM_EXEC_BUDGET/exec_rate , warmup*CONFIRM_WARMUP_MULT ,
#                  CONFIRM_MIN_SLICE ),  capped at the configured budget.
# So a saturated fast parser (tens of k execs/s, ~1s warm-up) collapses to ~1-2m,
# while a saturated slow/crypto target (few k/s, or a long warm-up) stays
# proportionally longer: the per-slice switch cost never dominates, and a "0 new
# coverage" verdict still rests on CONFIRM_EXEC_BUDGET fresh execs. Fail-safe — a
# target still finding, or whose throughput isn't measured yet, keeps its full
# configured budget and is never starved.
resolve_duration() {
  local fn="$1" dv="DURATION_${1}" configured rate warmup budget floor confirm cap
  configured="${!dv:-$DEFAULT_FUZZTIME}"
  [ "${REWEIGHT_CONFIRM:-off}" = on ] || { echo "$configured"; return; }
  is_saturated "$fn" || { echo "$configured"; return; }
  rate="$(measured_exec_rate "$fn")"
  [ "$rate" -gt 0 ] 2>/dev/null || { echo "$configured"; return; }
  warmup="$(measured_warmup_secs "$fn")"
  budget=$(( ${CONFIRM_EXEC_BUDGET:-5000000} / rate ))
  floor=$(( warmup * ${CONFIRM_WARMUP_MULT:-10} ))
  confirm="$budget"
  [ "$floor" -gt "$confirm" ] && confirm="$floor"
  [ "${CONFIRM_MIN_SLICE:-60}" -gt "$confirm" ] && confirm="${CONFIRM_MIN_SLICE:-60}"
  cap="$(dur_to_secs "$configured")"
  { [ "$cap" -gt 0 ] && [ "$confirm" -ge "$cap" ]; } && { echo "$configured"; return; }
  echo "${confirm}s"
}

# effective_report_mode -> local|private|pr|issue. The report SINK for a
# confirmed crash reproducer (renamed from CRASH_MODE, still honored as a
# deprecated alias — see main()). pr and issue are PUBLIC: pr opens a PR on the
# source repo, issue opens a GitHub issue on it. NEITHER is allowed for a
# standalone (third-party) module — a crash there is pre-disclosure 0-day
# material. Such a request is downgraded to private (push to the private
# CORPUS_REPO) when one is configured, else to local (on-box only).
# ALLOW_PUBLIC_FOR_STANDALONE=1 (alias: ALLOW_PR_FOR_STANDALONE=1) overrides.
effective_report_mode() {
  local m="${REPORT_MODE:-${CRASH_MODE:-local}}"   # CRASH_MODE = deprecated alias
  if [ "${SOURCE_MODE:-}" = "standalone" ] && { [ "$m" = "pr" ] || [ "$m" = "issue" ]; } \
     && [ "${ALLOW_PUBLIC_FOR_STANDALONE:-${ALLOW_PR_FOR_STANDALONE:-0}}" != "1" ]; then
    if [ -n "${CORPUS_REPO:-}" ]; then echo private; else echo local; fi
    return
  fi
  echo "$m"
}

sync_main() {   # git mode only; MUST be non-fatal (a fetch blip must never take the rig down)
  local i
  for ((i=1; i<=FETCH_RETRIES; i++)); do
    if git fetch "$GIT_REMOTE" "$GIT_BRANCH" -q 2>/dev/null; then
      git checkout "$GIT_BRANCH" -q 2>/dev/null || true
      git reset --hard "$GIT_REMOTE/$GIT_BRANCH" -q
      git clean -fd -q
      return 0
    fi
    log "fetch $GIT_REMOTE/$GIT_BRANCH failed ($i/$FETCH_RETRIES) — retry in $((FETCH_BACKOFF*i))s"
    sleep "$((FETCH_BACKOFF*i))"
  done
  log "fetch still failing — fuzzing existing checkout ($(git rev-parse --short HEAD 2>/dev/null || echo unknown))"
}

discover() {    # emit "pkg|Func"; drift-proof (same go test -list CI uses)
  local pkg
  while IFS= read -r pkg; do
    go test -list '^Fuzz' "$pkg" 2>/dev/null | grep '^Fuzz' | while IFS= read -r fn; do
      printf '%s|%s\n' "$pkg" "$fn"
    done
  done < <(go list ./... 2>/dev/null)
}

# filter_targets: drop any "pkg|Func" whose Func is listed in $EXCLUDE
# (space-separated Fuzz func names) — e.g. a saturated target on a pinned lib.
filter_targets() {
  local line fn
  while IFS= read -r line; do
    fn="${line##*|}"
    case " ${EXCLUDE:-} " in *" $fn "*) continue ;; esac
    printf '%s\n' "$line"
  done
}

# Everything the rigs back up lives on CORPUS_REPO's main branch — corpus under
# corpus/<project>/, crashers under crashers/<project>/ — so it's all visible in
# one place with no branches or PRs. A persistent working clone is kept in
# STATE_DIR; each write resets to origin/main, re-stages this rig's own subtree,
# commits and pushes with fetch/reset retry so concurrent rigs (disjoint
# subtrees) never clobber each other. All non-fatal.
STAGE_FN=""   # name of the staging callback push_to_main runs inside its retry loop
push_to_main() { # $1=commit message ; runs "$STAGE_FN" after each reset to (re)stage
  local msg="$1" wd a; wd="$STATE_DIR/corpus-main"
  [ -n "${CORPUS_REPO:-}" ] || { log "corpus: CORPUS_REPO unset — skipping ($msg)"; return 0; }
  if [ ! -d "$wd/.git" ]; then
    git clone -q "$CORPUS_REPO" "$wd" 2>/dev/null || { log "corpus: clone of $CORPUS_REPO failed (non-fatal)"; return 0; }
  fi
  ( cd "$wd" || exit 0
    for a in 1 2 3 4 5; do
      if ! { git fetch origin main -q 2>/dev/null && git reset --hard origin/main -q 2>/dev/null; }; then
        log "corpus: fetch/reset failed ($a/5)"; sleep 2; continue
      fi
      "$STAGE_FN" || { log "corpus: staging failed for '$msg'"; exit 0; }
      git add -A
      git diff --cached --quiet && exit 0   # nothing changed — no-op
      git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -s -m "$msg" 2>/dev/null || exit 0
      git push -q origin main 2>/dev/null && { log "corpus: pushed to main — $msg"; exit 0; }
      log "corpus: main push race ($a/5) — retrying"; sleep 1
    done
    log "corpus: main push retries exhausted (non-fatal) — $msg"
  )
}

# sync_corpus: back up the growing (interesting) corpus to corpus/<project>/ on
# main, once per rotation cycle. rsync --delete mirrors $GOCACHE/fuzz so the tree
# tracks the live corpus (git dedups unchanged content-addressed files).
_stage_corpus() {
  local proj="corpus/$CORPUS_PROJECT"
  mkdir -p "$proj"; rsync -a --delete "$CORPUS_GC"/ "$proj"/ 2>/dev/null
}
sync_corpus() {
  [ "${CORPUS_SYNC:-off}" = "on" ] || return 0
  CORPUS_GC="$(go env GOCACHE 2>/dev/null)/fuzz"
  [ -d "$CORPUS_GC" ] || { log "corpus sync: no $CORPUS_GC yet — nothing to back up"; return 0; }
  STAGE_FN=_stage_corpus
  push_to_main "corpus($CORPUS_PROJECT): snapshot $(date -u +%FT%TZ)"
}

# push_crasher_private: append a reproducer to crashers/<project>/<pkg>/<fn>/<ts>/
# on main. Non-fatal — the caller always keeps a local FINDINGS_DIR copy too.
_stage_crasher() {
  local dest="crashers/$CORPUS_PROJECT/${CRASH_PKG//\//_}/$CRASH_FN/$CRASH_TS" err
  mkdir -p "$dest" || { log "crasher stage: mkdir failed for $dest"; return 1; }
  # CRASH_SRC MUST be absolute: push_to_main cd's into the corpus checkout before
  # running this, so a path relative to the module dir would not resolve here.
  if ! err="$(cp -a "$CRASH_SRC"/. "$dest"/ 2>&1)"; then
    log "crasher stage: cp from '$CRASH_SRC' failed: $err"; return 1
  fi
}
push_crasher_private() {
  CRASH_FN="$1" CRASH_PKG="$2" CRASH_TS="$3" CRASH_SRC="$4"
  [ -n "$CRASH_SRC" ] || { log "CRASH $CRASH_FN: no reproducer dir — kept local only"; return 0; }
  STAGE_FN=_stage_crasher
  push_to_main "crash($CORPUS_PROJECT/$CRASH_FN): reproducer $CRASH_TS"
}

# --- saturation report (advisory only; never excludes anything) --------------
# sat_verdict <count> <sum> -> classification string for a target's recent runs.
sat_verdict() {
  local n="$1" s="$2"
  if [ "$n" -lt 3 ]; then echo "warming ($n runs)"
  elif [ "$s" -eq 0 ]; then echo "SATURATED (+0 over $n runs)"
  else echo "active (+$s over $n runs)"
  fi
}

# record_saturation <fn> -> append this run's final "new interesting" count to a
# per-target history file, trimmed to the last SATURATION_WINDOW runs.
record_saturation() {
  # Recorded when the advisory report is on OR the exec-rate reweight is on — the
  # reweight (resolve_duration/is_saturated) reads this same history, so it must
  # not depend on NOTIFY_URL / the report being enabled.
  { [ "${SATURATION_REPORT:-off}" = on ] || [ "${REWEIGHT_CONFIRM:-off}" = on ]; } || return 0
  local fn="$1" k f
  f="$STATE_DIR/sat/$fn"; mkdir -p "$STATE_DIR/sat"
  k="$(grep -aoE 'new interesting: [0-9]+' "$LOG_DIR/$fn.log" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"
  [ -n "$k" ] || return 0
  echo "$k" >> "$f"
  tail -n "${SATURATION_WINDOW:-10}" "$f" > "$STATE_DIR/sat.$fn.tmp" 2>/dev/null && mv "$STATE_DIR/sat.$fn.tmp" "$f"
}

# saturation_report -> once per SATURATION_REPORT_INTERVAL, push a per-target
# growth digest to NOTIFY_URL so a human can decide whether to EXCLUDE anything.
# Reports only — it never changes rotation.
saturation_report() {
  { [ "${SATURATION_REPORT:-off}" = on ] && [ -n "${NOTIFY_URL:-}" ]; } || return 0
  [ -d "$STATE_DIR/sat" ] || return 0
  local now last stamp="$STATE_DIR/last-sat-report" msg f fn n s
  now="$(date +%s)"; last="$(cat "$stamp" 2>/dev/null || echo 0)"
  [ "$(( now - last ))" -ge "${SATURATION_REPORT_INTERVAL:-21600}" ] || return 0
  msg="saturation ($CORPUS_PROJECT):"
  for f in "$STATE_DIR"/sat/*; do
    [ -e "$f" ] || continue
    fn="$(basename "$f")"
    n="$(awk 'END{print NR+0}' "$f")"; s="$(awk '{t+=$1} END{print t+0}' "$f")"
    msg="$msg
  $fn: $(sat_verdict "$n" "$s")"
  done
  notify "$msg"; echo "$now" > "$stamp"; log "saturation report sent"
}

# _find_repro_dir <fn> -> ABSOLUTE path of the go-fuzz reproducer dir for <fn>, or
# empty. Must be absolute: push_to_main cd's into the corpus checkout before
# staging, so a module-relative path (find ".") would break _stage_crasher.
_find_repro_dir() {
  find "$PWD" -type d -path "*/testdata/fuzz/$1" 2>/dev/null | head -1
}

# reproducer_reverifies <fn> <pkg> -> 0 (REAL: the saved input re-fails on replay) or
# 1 (TRANSIENT: it replays clean REVERIFY_RUNS times). A `go test -fuzz` non-zero exit
# that leaves a reproducer is treated as a crash by the caller — but Go also writes a
# "failing input" and exits non-zero when a fuzz WORKER dies for an EXTERNAL/resource
# reason (watchdog kill under CPU/IO load, e.g. during a corpus git-push), blaming
# whatever input was in flight. That input then replays clean. This replays the target's
# seed corpus (which now includes the just-written input) as a normal test, up to
# REVERIFY_RUNS times; ANY failure (including a REVERIFY_TIMEOUT hang, which is itself a
# real finding) means the crash reproduces. Only an all-clean replay is downgraded to a
# non-alert — so a genuinely reproducible crash is never suppressed. (2026-09-14: closes
# the dashdiag "~92% of CRASH alerts are harness noise" class.)
reproducer_reverifies() {
  local fn="$1" pkg="$2" i
  for ((i=1; i<=${REVERIFY_RUNS:-1}; i++)); do
    if ! go test "$pkg" -run="^${fn}\$" -timeout="${REVERIFY_TIMEOUT:-2m}" >>"$LOG_DIR/${fn}.reverify.log" 2>&1; then
      return 0   # re-failed → real crash
    fi
  done
  return 1        # every replay passed → transient, not a real crash
}

# quarantine_unverified <fn> -> keep a LOCAL copy of a reproducer that did not re-verify,
# under FINDINGS_DIR/<fn>/unverified-<ts>/, so a rare flaky-but-real crash is never lost —
# it is just not paged or pushed to the shared crasher repo on a single clean replay.
quarantine_unverified() {
  local fn="$1" ts src dest
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  src="$(_find_repro_dir "$fn")"; [ -n "$src" ] || return 0
  dest="$FINDINGS_DIR/$fn/unverified-$ts"; mkdir -p "$dest"
  cp -a "$src"/. "$dest"/ 2>/dev/null || true
}

handle_crash() { # $1=fn $2=pkg $3=rc ; called only when a real reproducer exists
  local fn="$1" pkg="$2" rc="$3" ts src dest mode body
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; mode="$(effective_report_mode)"
  src="$(_find_repro_dir "$fn")"   # absolute — see _find_repro_dir
  # Always keep a local copy first, so no reproducer is ever lost to a push failure.
  dest="$FINDINGS_DIR/$fn/$ts"; mkdir -p "$dest"
  [ -n "$src" ] && cp -a "$src"/. "$dest"/ 2>/dev/null
  case "$mode" in
    pr)
      log "CRASH $fn ($pkg) rc=$rc — opening PUBLIC PR on $CORPUS_BRANCH"
      git fetch "$GIT_REMOTE" "$GIT_BRANCH" -q 2>/dev/null || true
      git checkout "$GIT_BRANCH" -q 2>/dev/null || true
      git reset --hard "$GIT_REMOTE/$GIT_BRANCH" -q 2>/dev/null || true   # tracked-only; untracked reproducer survives
      git checkout -B "$CORPUS_BRANCH" -q
      git add -- '*/testdata/fuzz/*'
      git commit -q --signoff -m "test(fuzz): crash reproducer for $fn ($(date -u +%F))" || true
      git push -f -u "$GIT_REMOTE" "$CORPUS_BRANCH" -q 2>/dev/null || log "push failed for $CORPUS_BRANCH (non-fatal)"
      command -v gh >/dev/null && gh pr create --base "$GIT_BRANCH" --head "$CORPUS_BRANCH" \
        --title "fuzz(crash): $fn" --body "Crash reproducer for \`$fn\` in \`$pkg\`. Reproduce: \`go test -run='^$fn\$' $pkg\`." >/dev/null 2>&1 || true
      notify "CRASH (public PR) $fn in $pkg"
      ;;
    private)
      log "CRASH $fn ($pkg) rc=$rc — pushing to private $CORPUS_REPO (local copy -> $dest)"
      push_crasher_private "$fn" "$pkg" "$ts" "$src"
      notify "CRASH (private) $fn in $pkg -> $CORPUS_PROJECT"
      ;;
    issue)
      # PUBLIC GitHub issue as a repro POINTER — never the raw crashing input
      # (that stays local, and in the private CORPUS_REPO if configured), so
      # opening an issue on a public repo does not itself disclose the 0-day.
      log "CRASH $fn ($pkg) rc=$rc — opening a GitHub issue (repro pointer; raw input kept local -> $dest)"
      if command -v gh >/dev/null; then
        # shellcheck disable=SC2016  # single-quoted printf FORMAT: %s are printf specifiers, backticks are literal markdown
        body="$(printf 'A fuzz run for `%s` in `%s` exited non-zero and produced a reproducer (rc=%s, %s).\n\nReproduce on a checkout at this commit:\n\n```\ngo test -run='\''^%s$'\'' %s\n```\n\nThe crashing input is intentionally NOT included here (disclosure safety): it is on the rig under FINDINGS_DIR%s. Set ISSUE_INCLUDE_LOG=1 on the rig to attach a scrubbed log tail.' \
          "$fn" "$pkg" "$rc" "$ts" "$fn" "$pkg" "$([ -n "${CORPUS_REPO:-}" ] && printf ', and in the private corpus repo')")"
        if [ "${ISSUE_INCLUDE_LOG:-0}" = "1" ]; then
          body="${body}"$'\n\nLog tail:\n\n```\n'"$(tail -n 20 "$LOG_DIR/${fn}.log" 2>/dev/null | tr -d '`')"$'\n```'
        fi
        # ISSUE_REPO targets a specific repo; unset -> gh infers it from the module checkout.
        if [ -n "${ISSUE_REPO:-}" ]; then
          gh issue create --repo "$ISSUE_REPO" --title "fuzz(crash): $fn" --body "$body" >/dev/null 2>&1 \
            || log "gh issue create failed (non-fatal) — reproducer kept local -> $dest"
        else
          gh issue create --title "fuzz(crash): $fn" --body "$body" >/dev/null 2>&1 \
            || log "gh issue create failed (non-fatal) — reproducer kept local -> $dest"
        fi
      else
        log "gh not available — cannot open issue; reproducer kept local -> $dest"
      fi
      notify "CRASH (issue) $fn in $pkg"
      ;;
    *)
      log "CRASH $fn ($pkg) rc=$rc — reproducer(s) -> $dest (mode=local, NOT published)"
      notify "CRASH (local) $fn in $pkg -> $dest"
      ;;
  esac
}

main() {
  [ -r "$CONF" ] || { echo "fuzz-runner: config not found: $CONF" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "$CONF"
  : "${MODULE_DIR:?set MODULE_DIR in fuzz.conf}"
  : "${SOURCE_MODE:=standalone}"; : "${GIT_REMOTE:=origin}"; : "${GIT_BRANCH:=main}"
  # REPORT_MODE is the crash-reproducer report sink (local|private|pr|issue).
  # CRASH_MODE is the deprecated former name, still honored when REPORT_MODE is unset.
  : "${DEFAULT_FUZZTIME:=15m}"; : "${PARALLEL:=4}"; : "${REPORT_MODE:=${CRASH_MODE:-local}}"
  : "${STATE_DIR:=$MODULE_DIR-state}"; : "${LOG_DIR:=$MODULE_DIR-logs}"; : "${FINDINGS_DIR:=$MODULE_DIR-findings}"
  : "${CORPUS_BRANCH:=fuzz/corpus-updates}"; : "${NOTIFY_URL:=}"; : "${FETCH_RETRIES:=5}"; : "${FETCH_BACKOFF:=10}"
  : "${CORPUS_SYNC:=off}"; : "${CORPUS_REPO:=}"; : "${CORPUS_PROJECT:=$(basename "$MODULE_DIR")}"; : "${EXCLUDE:=}"
  : "${GIT_AUTHOR:=Andrei Beshkov}"; : "${GIT_EMAIL:=andrey.beshkov@gmail.com}"
  : "${SATURATION_REPORT:=off}"; : "${SATURATION_REPORT_INTERVAL:=21600}"; : "${SATURATION_WINDOW:=10}"
  # Exec-rate-scaled confirmation slices (off = unchanged behavior). When on, a
  # SATURATED target's slice is sized from its own throughput (see resolve_duration).
  : "${REWEIGHT_CONFIRM:=off}"; : "${CONFIRM_EXEC_BUDGET:=5000000}"; : "${CONFIRM_MIN_SLICE:=60}"
  : "${CONFIRM_WARMUP_MULT:=10}"; : "${CONFIRM_MIN_RUNS:=3}"
  # Re-verify a reproducer before alerting/pushing (on = suppress transient worker
  # deaths that don't actually reproduce; see reproducer_reverifies).
  : "${REVERIFY_CRASH:=on}"; : "${REVERIFY_RUNS:=1}"; : "${REVERIFY_TIMEOUT:=2m}"
  [ -n "${CRASH_MODE:-}" ] && echo "fuzz-runner: CRASH_MODE is deprecated — rename it to REPORT_MODE in fuzz.conf (honored for now)" >&2
  local eff; eff="$(effective_report_mode)"
  [ "$eff" = "${REPORT_MODE}" ] || echo "fuzz-runner: report mode $REPORT_MODE -> $eff for standalone module (disclosure safety)" >&2
  REPORT_MODE="$eff"
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$FINDINGS_DIR"
  CONF_HASH="$(sha256sum "$CONF" | cut -d' ' -f1)"
  cd "$MODULE_DIR" || { echo "fuzz-runner: MODULE_DIR not found: $MODULE_DIR" >&2; exit 1; }

  [ "$SOURCE_MODE" = "git" ] && sync_main
  mapfile -t TARGETS < <(discover | sort | filter_targets)
  [ "${#TARGETS[@]}" -gt 0 ] || { log "no fuzz targets discovered under $MODULE_DIR"; exit 1; }
  log "discovered ${#TARGETS[@]} target(s); mode=$SOURCE_MODE/$REPORT_MODE default=$DEFAULT_FUZZTIME corpus_sync=$CORPUS_SYNC"

  local POS_FILE="$STATE_DIR/rotation-pos" i=0 s
  if [ -r "$POS_FILE" ]; then s="$(cat "$POS_FILE" 2>/dev/null || echo 0)"; [[ "$s" =~ ^[0-9]+$ ]] && i=$(( s % ${#TARGETS[@]} )); fi

  local entry pkg fn dur d
  while true; do
    if [ "$(sha256sum "$CONF" | cut -d' ' -f1)" != "$CONF_HASH" ]; then
      log "fuzz.conf changed — reloading (resumes from rotation-pos)"; exec "$0" "$@"
    fi
    if [ "$i" -eq 0 ]; then
      [ "$SOURCE_MODE" = "git" ] && sync_main
      sync_corpus
      saturation_report
      mapfile -t NEW < <(discover | sort | filter_targets)
      if [ "${#NEW[@]}" -gt 0 ] && [ "${NEW[*]}" != "${TARGETS[*]}" ]; then
        log "target set changed (${#TARGETS[@]} -> ${#NEW[@]}) — reloading"; exec "$0" "$@"
      fi
    elif [ "$SOURCE_MODE" = "git" ]; then
      sync_main
    fi
    entry="${TARGETS[$i]}"; pkg="${entry%%|*}"; fn="${entry##*|}"; dur="$(resolve_duration "$fn")"
    echo "$(( (i+1) % ${#TARGETS[@]} ))" > "$POS_FILE"
    log "=== fuzzing $fn ($pkg) for $dur ==="
    go test "$pkg" -run='^$' -fuzz="^${fn}\$" -parallel="$PARALLEL" -fuzztime="$dur" >>"$LOG_DIR/${fn}.log" 2>&1
    rc=$?
    d="$(find . -type d -path "*/testdata/fuzz/$fn" 2>/dev/null | head -1)"
    if [ -n "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
      # A reproducer exists. Unless it re-verifies (replays and re-fails), treat it as a
      # transient worker death — keep a local copy but do NOT alert or push. Only a
      # confirmed-reproducing input reaches handle_crash. REVERIFY_CRASH=off restores the
      # old always-alert behavior.
      if [ "${REVERIFY_CRASH:-on}" = on ] && ! reproducer_reverifies "$fn" "$pkg"; then
        log "$fn: reproducer did NOT re-fail on ${REVERIFY_RUNS:-1}x replay — transient worker death, not alerting (local copy kept in $FINDINGS_DIR/$fn)"
        quarantine_unverified "$fn"
      else
        handle_crash "$fn" "$pkg" "$rc"
      fi
    elif [ "$rc" -ne 0 ]; then
      log "$fn exited $rc with no reproducer — infra/timeout, logged not alerted"
    fi
    record_saturation "$fn"
    i=$(( (i+1) % ${#TARGETS[@]} ))
  done
}

CONF="${FUZZ_CONF:-$SCRIPT_DIR/fuzz.conf}"
[ -n "${FUZZ_RUNNER_LIB:-}" ] && return 0 2>/dev/null   # test hook: source for functions only
main "$@"
