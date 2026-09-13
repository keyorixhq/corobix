#!/usr/bin/env bash
# fuzz-runner.sh — universal continuous-fuzz rotation runner (native go test -fuzz).
# Config: fuzz.conf beside this script, or $FUZZ_CONF. See README.md and the
# Keyorix project doc claude/2026-09-13-universal-fuzz-harness-spec.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()   { echo "[$(date -u +%FT%TZ)] $*" | tee -a "${LOG_DIR:-/tmp}/rotation.log" >&2; }
notify(){ [ -n "${NOTIFY_URL:-}" ] && curl -fsS -m 10 -d "$1" "$NOTIFY_URL" >/dev/null 2>&1 || true; }

# resolve_duration <FuzzFunc> -> per-target override (DURATION_<fn>) or DEFAULT_FUZZTIME
resolve_duration() { local dv="DURATION_${1}"; echo "${!dv:-$DEFAULT_FUZZTIME}"; }

# effective_crash_mode -> local|pr|private.
# pr = PUBLIC (opens a PR on the source repo). NEVER allowed for a standalone
# (third-party) module — a crash there is pre-disclosure 0-day material. Such a
# request is downgraded to private (push to the private CORPUS_REPO) when one is
# configured, else to local (on-box only). ALLOW_PR_FOR_STANDALONE=1 overrides.
effective_crash_mode() {
  local m="${CRASH_MODE:-local}"
  if [ "${SOURCE_MODE:-}" = "standalone" ] && [ "$m" = "pr" ] && [ "${ALLOW_PR_FOR_STANDALONE:-0}" != "1" ]; then
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
  local dest="crashers/$CORPUS_PROJECT/${CRASH_PKG//\//_}/$CRASH_FN/$CRASH_TS"
  mkdir -p "$dest"; cp -a "$CRASH_SRC"/. "$dest"/ 2>/dev/null
}
push_crasher_private() {
  CRASH_FN="$1" CRASH_PKG="$2" CRASH_TS="$3" CRASH_SRC="$4"
  [ -n "$CRASH_SRC" ] || { log "CRASH $CRASH_FN: no reproducer dir — kept local only"; return 0; }
  STAGE_FN=_stage_crasher
  push_to_main "crash($CORPUS_PROJECT/$CRASH_FN): reproducer $CRASH_TS"
}

handle_crash() { # $1=fn $2=pkg $3=rc ; called only when a real reproducer exists
  local fn="$1" pkg="$2" rc="$3" ts src dest mode
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; mode="$(effective_crash_mode)"
  src="$(find . -type d -path "*/testdata/fuzz/$fn" 2>/dev/null | head -1)"
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
  : "${DEFAULT_FUZZTIME:=15m}"; : "${PARALLEL:=4}"; : "${CRASH_MODE:=local}"
  : "${STATE_DIR:=$MODULE_DIR-state}"; : "${LOG_DIR:=$MODULE_DIR-logs}"; : "${FINDINGS_DIR:=$MODULE_DIR-findings}"
  : "${CORPUS_BRANCH:=fuzz/corpus-updates}"; : "${NOTIFY_URL:=}"; : "${FETCH_RETRIES:=5}"; : "${FETCH_BACKOFF:=10}"
  : "${CORPUS_SYNC:=off}"; : "${CORPUS_REPO:=}"; : "${CORPUS_PROJECT:=$(basename "$MODULE_DIR")}"; : "${EXCLUDE:=}"
  : "${GIT_AUTHOR:=Andrei Beshkov}"; : "${GIT_EMAIL:=andrey.beshkov@gmail.com}"
  local eff; eff="$(effective_crash_mode)"
  [ "$eff" = "${CRASH_MODE}" ] || echo "fuzz-runner: crash mode $CRASH_MODE -> $eff for standalone module (disclosure safety)" >&2
  CRASH_MODE="$eff"
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$FINDINGS_DIR"
  CONF_HASH="$(sha256sum "$CONF" | cut -d' ' -f1)"
  cd "$MODULE_DIR" || { echo "fuzz-runner: MODULE_DIR not found: $MODULE_DIR" >&2; exit 1; }

  [ "$SOURCE_MODE" = "git" ] && sync_main
  mapfile -t TARGETS < <(discover | sort | filter_targets)
  [ "${#TARGETS[@]}" -gt 0 ] || { log "no fuzz targets discovered under $MODULE_DIR"; exit 1; }
  log "discovered ${#TARGETS[@]} target(s); mode=$SOURCE_MODE/$CRASH_MODE default=$DEFAULT_FUZZTIME corpus_sync=$CORPUS_SYNC"

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
      handle_crash "$fn" "$pkg" "$rc"
    elif [ "$rc" -ne 0 ]; then
      log "$fn exited $rc with no reproducer — infra/timeout, logged not alerted"
    fi
    i=$(( (i+1) % ${#TARGETS[@]} ))
  done
}

CONF="${FUZZ_CONF:-$SCRIPT_DIR/fuzz.conf}"
[ -n "${FUZZ_RUNNER_LIB:-}" ] && return 0 2>/dev/null   # test hook: source for functions only
main "$@"
