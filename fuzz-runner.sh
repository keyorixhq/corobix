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

# sync_corpus: off-box backup of the growing (interesting) corpus. Snapshots
# $GOCACHE/fuzz to the private CORPUS_REPO's orphan branch corpus/<project>,
# force-pushed (disposable, size-bounded cache — no history). Non-fatal, and only
# when CORPUS_SYNC=on. Called once per rotation cycle, never per-target.
sync_corpus() {
  [ "${CORPUS_SYNC:-off}" = "on" ] || return 0
  [ -n "${CORPUS_REPO:-}" ] || { log "CORPUS_SYNC=on but CORPUS_REPO unset — skipping"; return 0; }
  local gc wd br sz
  gc="$(go env GOCACHE 2>/dev/null)/fuzz"
  [ -d "$gc" ] || { log "corpus sync: no $gc yet — nothing to back up"; return 0; }
  wd="$STATE_DIR/corpus-cache"; br="corpus/$CORPUS_PROJECT"
  rm -rf "$wd"; mkdir -p "$wd/corpus"
  ( cd "$wd" || exit 0
    git init -q -b "$br"; git remote add origin "$CORPUS_REPO"
    rsync -a --delete "$gc"/ ./corpus/ 2>/dev/null
    git add -A
    git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
      commit -q -s -m "corpus($CORPUS_PROJECT): snapshot $(date -u +%FT%TZ)" 2>/dev/null \
      || { log "corpus sync: nothing to commit"; exit 0; }
    sz="$(du -sh "$gc" 2>/dev/null | cut -f1)"
    if git push -q -f origin "$br" 2>/dev/null; then
      log "corpus sync: pushed $br ($sz)"
    else
      log "corpus sync: push to $br failed (non-fatal — will retry next cycle)"
    fi
  )
  rm -rf "$wd"
}

# push_crasher_private: copy a reproducer into the private CORPUS_REPO main under
# crashers/<project>/<pkg>/<fn>/<ts>/ and push (append-only, retry on races).
# Non-fatal — the reproducer is always also kept locally by the caller.
push_crasher_private() {
  local fn="$1" pkg="$2" ts="$3" srcdir="$4" wd dest a
  [ -n "${CORPUS_REPO:-}" ] || { log "CRASH $fn: private mode but CORPUS_REPO unset — kept local only"; return 0; }
  wd="$STATE_DIR/corpus-crashers"; dest="crashers/$CORPUS_PROJECT/${pkg//\//_}/$fn/$ts"
  [ -d "$wd/.git" ] || git clone -q --depth 1 "$CORPUS_REPO" "$wd" 2>/dev/null \
    || { log "CRASH $fn: corpus clone failed — kept local only"; return 0; }
  ( cd "$wd" || exit 0
    for a in 1 2 3; do
      git fetch origin main -q 2>/dev/null && git reset --hard origin/main -q 2>/dev/null
      mkdir -p "$dest"; cp -a "$srcdir"/. "$dest"/ 2>/dev/null
      git add -A
      git -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" \
        commit -q -s -m "crash($CORPUS_PROJECT/$fn): reproducer $ts" 2>/dev/null || { exit 0; }
      git push -q origin main 2>/dev/null && { log "CRASH $fn: pushed to $CORPUS_REPO ($dest)"; exit 0; }
      log "CRASH $fn: push race ($a/3) — retrying"
    done
    log "CRASH $fn: private push retries exhausted — kept local"
  )
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
  : "${CORPUS_SYNC:=off}"; : "${CORPUS_REPO:=}"; : "${CORPUS_PROJECT:=$(basename "$MODULE_DIR")}"
  : "${GIT_AUTHOR:=Andrei Beshkov}"; : "${GIT_EMAIL:=andrey.beshkov@gmail.com}"
  local eff; eff="$(effective_crash_mode)"
  [ "$eff" = "${CRASH_MODE}" ] || echo "fuzz-runner: crash mode $CRASH_MODE -> $eff for standalone module (disclosure safety)" >&2
  CRASH_MODE="$eff"
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$FINDINGS_DIR"
  CONF_HASH="$(sha256sum "$CONF" | cut -d' ' -f1)"
  cd "$MODULE_DIR" || { echo "fuzz-runner: MODULE_DIR not found: $MODULE_DIR" >&2; exit 1; }

  [ "$SOURCE_MODE" = "git" ] && sync_main
  mapfile -t TARGETS < <(discover | sort)
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
      mapfile -t NEW < <(discover | sort)
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
