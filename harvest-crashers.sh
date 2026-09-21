#!/usr/bin/env bash
# harvest-crashers.sh — runner-independent guard: every go-fuzz failing input on this
# box is copied off-box to the private fuzz-corpus repo, whatever started the run.
#
# Why (2026-09-21): crash saving lived only in fuzz-runner.sh's handle_crash. Over the
# 2026-09-19..21 weekend the managed services were stopped and ad-hoc loops ran
# `go test -fuzz` directly; 12 failing inputs on vcd-dashdiag-fuzz sat untracked in a
# checkout for ~24h — never pushed, never archived, and a watchdog judged them "old".
# Go writes testdata/fuzz/<Fn>/<file> ONLY when a target fails, so an untracked file
# there IS a finding. This script keys on that file, not on any runner's bookkeeping.
#
# Default mode (cron, every 5 min):
#   1. scan   every git checkout under HARVEST_ROOTS -> untracked */testdata/fuzz/<Fn>/<file>
#             (git-ignored files included: ls-files --others without --exclude-standard)
#   2. spool  each new one -> $HARVEST_STATE/spool/<project>/<pkg>/<Fn>/<file>/ with the
#             input, meta.txt and every *.log under HARVEST_LOG_ROOTS that names it.
#             Local copy FIRST: a later git clean / reclone / checkout can't lose it.
#   3. push   spool -> crashers/<same path>/ on fuzz-corpus $CORPUS_BRANCH (shallow +
#             sparse clone; fetch/reset/retry like fuzz-runner's push_to_main). Only
#             after a successful push does a bundle move to $HARVEST_STATE/archive/.
# --check        exit 2 with ALERT lines if: an input on disk is neither spooled nor
#                archived; a bundle is unpushed > HARVEST_ALERT_MIN; or the last scan is
#                older than HARVEST_STALE_MIN (harvester not running). Else prints OK.
# --dry-run      list what the next tick would harvest; writes nothing.
# --install-cron idempotently install the */5 crontab line (marker "# fuzz-harvest").
#
# It never classifies (real vs harness noise): triage is a human job, saving is not.
# The fuzz-corpus repo is PRIVATE by design (pre-disclosure material) — see its README.
set -uo pipefail

HARVEST_STATE=${HARVEST_STATE:-$HOME/.fuzz-harvest}
HARVEST_ROOTS=${HARVEST_ROOTS:-$HOME}            # space-separated
HARVEST_LOG_ROOTS=${HARVEST_LOG_ROOTS:-$HARVEST_ROOTS}
HARVEST_MAX_DEPTH=${HARVEST_MAX_DEPTH:-6}        # how deep to look for checkouts
HARVEST_MAX_LOGS=${HARVEST_MAX_LOGS:-5}
HARVEST_MAX_LOG_BYTES=${HARVEST_MAX_LOG_BYTES:-2000000}   # a log is tail-truncated to this
HARVEST_ALERT_MIN=${HARVEST_ALERT_MIN:-30}
HARVEST_STALE_MIN=${HARVEST_STALE_MIN:-20}
HARVEST_HOST=${HARVEST_HOST:-$(hostname -s 2>/dev/null || hostname)}
CORPUS_REPO=${CORPUS_REPO:-github-fuzzcorpus:keyorixhq/fuzz-corpus.git}
CORPUS_BRANCH=${CORPUS_BRANCH:-main}
GIT_AUTHOR=${GIT_AUTHOR:-fuzz-harvest}
GIT_EMAIL=${GIT_EMAIL:-fuzz-harvest@$HARVEST_HOST}
NOTIFY_URL=${NOTIFY_URL:-}

SPOOL="$HARVEST_STATE/spool"; ARCHIVE="$HARVEST_STATE/archive"; STATUS="$HARVEST_STATE/status"

hlog()   { echo "[$(date -u +%FT%TZ)] $*"; }
notify() { [ -n "$NOTIFY_URL" ] && curl -fsS -m 10 -d "$1" "$NOTIFY_URL" >/dev/null 2>&1 || true; }

# --- portability (Linux rigs + macOS for tests) -----------------------------------
sha256_of()   { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
mtime_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
epoch_utc()   { date -u -d "@$1" +%FT%TZ 2>/dev/null || date -u -r "$1" +%FT%TZ; }
count_dirs4() { [ -d "$1" ] || { echo 0; return; }; (cd "$1" && find . -mindepth 4 -maxdepth 4 -type d | wc -l | tr -d ' '); }

# --- scan ---------------------------------------------------------------------------
# find_repos -> top dir of every git checkout (dir or worktree .git file) under the
# roots. Build/module caches and our own state are pruned: they are huge and hold
# only tracked/third-party seeds, never a first-run failing input.
find_repos() {
  local r
  for r in $HARVEST_ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth "$HARVEST_MAX_DEPTH" \
      \( -name '*gocache*' -o -name gomodcache -o -name .cache -o -name node_modules \
         -o -path '*/pkg/mod' -o -path "$HARVEST_STATE" \) -prune \
      -o -name .git -print -prune 2>/dev/null
  done | while IFS= read -r g; do dirname "$g"; done | sort -u
}

# untracked_inputs <repo> -> absolute path of each untracked testdata/fuzz/<Fn>/<file>
untracked_inputs() {
  git -C "$1" ls-files --others -z -- ':(glob)**/testdata/fuzz/*/*' 2>/dev/null |
    while IFS= read -r -d '' p; do printf '%s\n' "$1/$p"; done
}

all_inputs() { local r; find_repos | while IFS= read -r r; do untracked_inputs "$r"; done; }

# bundle_rel <input> -> "<project>/<import_path_with_underscores>/<Fn>/<file>"
# (same shape as fuzz-runner's crashers/<project>/<pkg>/<Fn>/..., keyed by the input's
# own content-hash name instead of a timestamp, so re-sightings and two rigs dedupe).
bundle_rel() {
  local in="$1" fn base pkgdir d mod="" moddir="" rel proj imp
  base=$(basename "$in"); fn=$(basename "$(dirname "$in")")
  pkgdir=$(dirname "$(dirname "$(dirname "$(dirname "$in")")")")   # strip testdata/fuzz/<Fn>/<file>
  d="$pkgdir"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/go.mod" ]; then mod=$(awk '$1=="module"{print $2; exit}' "$d/go.mod"); moddir="$d"; break; fi
    d=$(dirname "$d")
  done
  if [ -z "$mod" ]; then mod="unknown/$(basename "$pkgdir")"; moddir="$pkgdir"; fi
  rel="${pkgdir#"$moddir"}"; rel="${rel#/}"
  proj=${HARVEST_PROJECT:-$(basename "$mod")}
  case "$proj" in v[0-9]*) proj=$(basename "$(dirname "$mod")");; esac
  imp="$mod${rel:+/$rel}"
  printf '%s/%s/%s/%s\n' "$proj" "${imp//\//_}" "$fn" "$base"
}

known() { [ -d "$SPOOL/$1" ] || [ -d "$ARCHIVE/$1" ]; }

# logs_naming <Fn> <file> -> up to HARVEST_MAX_LOGS *.log files that mention the input
logs_naming() {
  local r
  for r in $HARVEST_LOG_ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 8 \( -name '*gocache*' -o -name gomodcache -o -name .git \
         -o -path '*/pkg/mod' -o -path "$HARVEST_STATE" \) -prune \
      -o -type f -name '*.log' -print0 2>/dev/null
  done | xargs -0 grep -lF -- "$1/$2" 2>/dev/null | head -n "$HARVEST_MAX_LOGS"
}

spool_one() { # <input> <rel>
  local in="$1" rel="$2" dest top fn base lg n=0
  dest="$SPOOL/$rel"; mkdir -p "$dest/logs" || return 1
  cp -p "$in" "$dest/" || { rm -rf "$dest"; return 1; }
  fn=$(basename "$(dirname "$in")"); base=$(basename "$in")
  top=$(git -C "$(dirname "$in")" rev-parse --show-toplevel 2>/dev/null)
  {
    echo "host=$HARVEST_HOST"
    echo "source=$in"
    echo "repo=$top"
    echo "repo_remote=$(git -C "$top" remote get-url origin 2>/dev/null)"
    echo "repo_head_at_harvest=$(git -C "$top" rev-parse HEAD 2>/dev/null) (the run's own commit is in its slice log header, if the runner printed one)"
    echo "input_sha256=$(sha256_of "$in")"
    echo "input_mtime=$(epoch_utc "$(mtime_epoch "$in")")"
    echo "spooled_epoch=$(date +%s)"
    echo "spooled_at=$(date -u +%FT%TZ)"
    echo "replay=go test -run='^$fn/$base\$' ./<pkg>   # from the repo, at the run's commit"
  } > "$dest/meta.txt"
  while IFS= read -r lg; do
    [ -n "$lg" ] || continue; n=$((n+1))
    tail -c "$HARVEST_MAX_LOG_BYTES" "$lg" > "$dest/logs/$(basename "$lg")"
    echo "log=$lg" >> "$dest/meta.txt"
  done < <(logs_naming "$fn" "$base")
  [ "$n" -gt 0 ] || echo "log=NONE FOUND under $HARVEST_LOG_ROOTS" >> "$dest/meta.txt"
  # the failure block from the first log, so the repo view is readable without the log
  lg=$(find "$dest/logs" -type f | head -1)
  if [ -n "$lg" ]; then
    { echo "--- failure (first log) ---"; grep -m1 -A8 -- '--- FAIL' "$lg"; } >> "$dest/meta.txt"
  fi
  return 0
}

scan_and_spool() { # -> number of new bundles on stdout (last line)
  local in rel new=0 names=""
  while IFS= read -r in; do
    [ -f "$in" ] || continue
    rel=$(bundle_rel "$in")
    known "$rel" && continue
    if spool_one "$in" "$rel"; then
      new=$((new+1)); names="$names $(basename "$(dirname "$in")")"
      hlog "spooled $rel  (from $in)" >&2
    else
      hlog "SPOOL FAILED for $in" >&2
    fi
  done < <(all_inputs)
  if [ "$new" -gt 0 ]; then notify "fuzz-harvest $HARVEST_HOST: $new new failing input(s):$names"; fi
  echo "$new"
}

# --- push ---------------------------------------------------------------------------
pending() { [ -d "$SPOOL" ] && (cd "$SPOOL" && find . -mindepth 4 -maxdepth 4 -type d | sed 's|^\./||' | sort); }

corpus_checkout() { # -> path of a shallow, sparse (crashers/ only) clone
  local wd="$HARVEST_STATE/corpus"
  if [ ! -d "$wd/.git" ]; then
    rm -rf "$wd"
    git clone -q --depth 1 --filter=blob:none --no-checkout --branch "$CORPUS_BRANCH" \
      "$CORPUS_REPO" "$wd" 2>/dev/null || return 1
    git -C "$wd" sparse-checkout set crashers >/dev/null 2>&1 || return 1
    git -C "$wd" checkout -q "$CORPUS_BRANCH" 2>/dev/null || return 1
  fi
  echo "$wd"
}

push_spool() {
  local list n wd a rel
  list=$(pending); [ -n "$list" ] || return 0
  n=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
  wd=$(corpus_checkout) || { hlog "push: clone of $CORPUS_REPO failed — $n bundle(s) stay spooled"; return 1; }
  for a in 1 2 3 4 5; do
    if ! { git -C "$wd" fetch -q --depth 1 origin "$CORPUS_BRANCH" 2>/dev/null \
           && git -C "$wd" reset -q --hard FETCH_HEAD 2>/dev/null; }; then
      hlog "push: fetch/reset failed ($a/5)"; sleep 2; continue
    fi
    while IFS= read -r rel; do
      mkdir -p "$wd/crashers/$rel" && cp -R "$SPOOL/$rel/." "$wd/crashers/$rel/"
    done <<< "$list"
    git -C "$wd" add -A -- crashers
    if ! git -C "$wd" diff --cached --quiet; then
      git -C "$wd" -c user.name="$GIT_AUTHOR" -c user.email="$GIT_EMAIL" commit -q -s \
        -m "crash(harvest): $n failing input(s) from $HARVEST_HOST" -m "$list" || { hlog "push: commit failed"; return 1; }
      if ! git -C "$wd" push -q origin "HEAD:$CORPUS_BRANCH" 2>/dev/null; then
        hlog "push: race/failure ($a/5) — retrying"; sleep "$a"; continue
      fi
    fi
    while IFS= read -r rel; do   # only what this attempt carried
      mkdir -p "$ARCHIVE/$(dirname "$rel")"; rm -rf "${ARCHIVE:?}/$rel"; mv "$SPOOL/$rel" "$ARCHIVE/$rel"
    done <<< "$list"
    find "$SPOOL" -mindepth 1 -type d -empty -delete 2>/dev/null
    date +%s > "$HARVEST_STATE/last_push_epoch"
    hlog "pushed $n bundle(s) to $CORPUS_REPO:crashers/"
    return 0
  done
  hlog "push: retries exhausted — $n bundle(s) stay spooled"
  return 1
}

# --- modes --------------------------------------------------------------------------
tick() {
  local new rc=0
  new=$(scan_and_spool | tail -1)
  push_spool || rc=1
  { echo "last_scan_epoch=$(date +%s)"; echo "last_new=$new"; echo "pending=$(count_dirs4 "$SPOOL")"; } > "$STATUS"
  return $rc
}

check() {
  local now rc=0 last in rel ep age lp
  now=$(date +%s)
  last=$(sed -n 's/^last_scan_epoch=//p' "$STATUS" 2>/dev/null)
  if [ -z "$last" ]; then echo "ALERT $HARVEST_HOST: harvester has never completed a scan"; rc=2
  elif [ $(( (now - last) / 60 )) -ge "$HARVEST_STALE_MIN" ]; then
    echo "ALERT $HARVEST_HOST: last harvest scan $(( (now - last) / 60 ))m ago — harvester not running?"; rc=2
  fi
  while IFS= read -r in; do
    [ -f "$in" ] || continue
    rel=$(bundle_rel "$in"); known "$rel" && continue
    echo "ALERT $HARVEST_HOST: failing input not harvested: $in"; rc=2
  done < <(all_inputs)
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    ep=$(sed -n 's/^spooled_epoch=//p' "$SPOOL/$rel/meta.txt" 2>/dev/null); ep=${ep:-0}
    age=$(( (now - ep) / 60 ))
    if [ "$age" -ge "$HARVEST_ALERT_MIN" ]; then echo "ALERT $HARVEST_HOST: unpushed for ${age}m: $rel"; rc=2; fi
  done < <(pending)
  if [ $rc -eq 0 ]; then
    lp=$(cat "$HARVEST_STATE/last_push_epoch" 2>/dev/null)
    echo "OK $HARVEST_HOST: pushed=$(count_dirs4 "$ARCHIVE") pending=$(count_dirs4 "$SPOOL") last_scan=$(( (now - last) / 60 ))m_ago last_push=${lp:+$(epoch_utc "$lp")}"
  fi
  return $rc
}

dry_run() {
  local in rel
  while IFS= read -r in; do
    [ -f "$in" ] || continue
    rel=$(bundle_rel "$in")
    if known "$rel"; then echo "known  $rel"; else echo "NEW    $rel  <- $in"; fi
  done < <(all_inputs)
}

install_cron() {
  local self line
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  mkdir -p "$HARVEST_STATE"
  line="*/5 * * * * HARVEST_ROOTS='$HARVEST_ROOTS' CORPUS_REPO='$CORPUS_REPO' $self >> $HARVEST_STATE/harvest.log 2>&1 # fuzz-harvest"
  { crontab -l 2>/dev/null | grep -v '# fuzz-harvest$'; echo "$line"; } | crontab - && echo "installed: $line"
}

main() {
  mkdir -p "$HARVEST_STATE" "$SPOOL" "$ARCHIVE"
  case "${1:-}" in
    --check)        check ;;
    --dry-run)      dry_run ;;
    --install-cron) install_cron ;;
    "")
      exec 9>"$HARVEST_STATE/lock"
      if command -v flock >/dev/null; then flock -n 9 || { hlog "previous tick still running — skip"; exit 0; }; fi
      tick ;;
    *) echo "usage: $0 [--check|--dry-run|--install-cron]" >&2; return 64 ;;
  esac
}

[ -n "${HARVEST_LIB:-}" ] || main "$@"
