#!/usr/bin/env bash
# fuzz-lane.sh: run fuzz targets on a spare host and report only what matters.
#   fuzz-lane.sh REF PKG TARGET[,TARGET...] [TOTAL_MINUTES]
#   fuzz-lane.sh --selftest            (exercises the report path with a fake finding)
# Reports: ntfy (if ~/.config/fuzz-lane/ntfy-url exists) and a de-duplicated issue in
# keyorixhq/fuzz-corpus (if ~/.config/fuzz-lane/issues-token exists). Crasher bytes stay on
# this host under ~/lane/crashers; the issue carries only target, commit and path.
#
# This is the tracked copy. The live copy on vcd-keyorix-fuzz (~/fuzz-lane.sh) was
# untracked until now — redeploy from here rather than editing it in place.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/fuzz-report.sh
source "$SCRIPT_DIR/../lib/fuzz-report.sh"
# shellcheck source=../lib/exit-classify.sh
source "$SCRIPT_DIR/../lib/exit-classify.sh"
export PATH=$PATH:/usr/local/go/bin:/snap/bin
LANE=$HOME/lane; CFG=$HOME/.config/fuzz-lane; HOST=$(hostname)
REPO=keyorixhq/fuzz-corpus
mkdir -p "$LANE/logs" "$LANE/crashers" "$LANE/state"
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LANE/status.log"; }

notify() { # title, message, priority
  [ -r "$CFG/ntfy-url" ] || return 0
  curl -fsS -H "Title: $1" -H "Priority: ${3:-default}" -d "$2" "$(cat "$CFG/ntfy-url")" >/dev/null 2>&1 || true
}
issue() { # target, hash, body ; one issue per target and crasher, one issue per new hash, at most 5 per target per 24h
  [ -r "$CFG/issues-token" ] || { log "issue skipped: no token file"; return 0; }
  local t=$1 h=$2 body=$3 stamp="$LANE/state/issue-$1.ts" now; now=$(date +%s)
  # storm guard: at most 5 new issues per target per 24h (one line per issue in the stamp file)
  if [ -f "$stamp" ]; then
    local recent; recent=$(awk -v n="$now" 'n-$1<86400' "$stamp" | wc -l)
    if [ "$recent" -ge 5 ]; then log "issue skipped: storm guard (5/24h) for $t hash=$h"; return 0; fi
  fi
  TOKEN=$(tr -d '[:space:]' < "$CFG/issues-token") REPO=$REPO T=$t H=$h BODY=$body python3 - <<'PY'
import json, os, urllib.request
tok, repo, t, h, body = (os.environ[k] for k in ("TOKEN", "REPO", "T", "H", "BODY"))
title = f"[vcd-auto] {t} crasher {h}"
def call(method, url, data=None):
    req = urllib.request.Request("https://api.github.com" + url, method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)
existing = call("GET", f"/repos/{repo}/issues?state=all&labels=vcd-auto&per_page=100")
for i in existing:
    if i["title"] == title:
        call("POST", f"/repos/{repo}/issues/{i['number']}/comments", {"body": "Seen again.\n\n" + body})
        print("commented", i["number"]); raise SystemExit
n = call("POST", f"/repos/{repo}/issues", {"title": title, "body": body, "labels": ["vcd-auto"]})
print("created", n["number"])
PY
  local rc=$?; [ $rc -eq 0 ] && echo "$now" >> "$stamp"; log "issue rc=$rc target=$t hash=$h"
}

report() { # target, crasher-file-list-file, commit, ref, pkg
  local t=$1 list=$2 commit=$3 ref=$4 pkg=$5 h dest
  h=$(cat $(cat "$list") 2>/dev/null | sha256sum | cut -c1-12); [ -n "$h" ] || h=nohash
  dest="$LANE/crashers/$t/$h"; mkdir -p "$dest"; while read -r f; do cp "$f" "$dest/"; done < "$list"
  log "FINDING target=$t hash=$h saved=$dest"
  notify "Fuzz finding: $t" "$(fuzz_report_msg lane "$t" "$pkg" "$dest" "at $commit ($ref)")" high
  issue "$t" "$h" "Host: $HOST
Ref: $ref ($commit)
Package: $pkg
Target: $t
Crasher: $dest (bytes are not in this issue; pull them over ssh)
Repro: go test -run '^$t\$/$h' ... or copy the file into testdata/fuzz/$t/ and run go test -run $t $pkg
Status: unverified. Minimise, replay three times, check the registry for a duplicate, trace to a live caller before any claim."
}
if [ "${1:-}" = "--selftest" ]; then
  d=$(mktemp -d); echo "selftest" > "$d/seed"; echo "$d/seed" > "$d/list"
  FZ_SELFTEST=1 report SelfTest "$d/list" selftest-commit selftest-ref ./selftest; rm -rf "$d"; exit 0
fi

REF=${1:?ref}; PKG=${2:?pkg}; TARGETS=${3:?targets}; TOTAL=${4:-120}
CHUNK=${CHUNK:-540s}
FUZZ_REPO=${FUZZ_REPO:-keyorixhq/keyorix}; SRC=$LANE/${FUZZ_REPO##*/}
[ -d "$SRC/.git" ] || git clone -q "https://github.com/$FUZZ_REPO" "$SRC" || { log "clone failed"; exit 1; }
cd "$SRC" && git fetch -q origin "$REF" && git checkout -q --detach FETCH_HEAD && git clean -fdq || { log "checkout $REF failed"; exit 1; }
COMMIT=$(git rev-parse --short HEAD)
IFS=, read -ra TL <<< "$TARGETS"
PER=$(( TOTAL / ${#TL[@]} )); [ "$PER" -ge 1 ] || PER=1
log "lane start ref=$REF commit=$COMMIT pkg=$PKG targets=$TARGETS per-target=${PER}min chunk=$CHUNK"
CSEC=${CHUNK%s}; FOUND=0
for T in "${TL[@]}"; do
  spent=0
  while [ $((spent*60)) -lt $((PER*60)) ]; do
    start=$(date +%s)
    GOMAXPROCS=3 nice -n 10 go test -run '^$' -fuzz "^${T}\$" -fuzztime "$CHUNK" -parallel 3 "$PKG" > "$LANE/logs/$T.last.log" 2>&1; rc=$?
    spent=$(( spent + (($(date +%s) - start) + 59) / 60 ))
    if [ $rc -ne 0 ]; then
      pkgdir=$(go list -f '{{.Dir}}' "$PKG" 2>/dev/null)
      git status --porcelain --untracked-files=all -- "$pkgdir/testdata/fuzz/$T" | awk '{print $2}' | sed "s#^#$SRC/#" > "$LANE/state/new.list"
      if [ -s "$LANE/state/new.list" ]; then FOUND=$((FOUND+1)); report "$T" "$LANE/state/new.list" "$COMMIT" "$REF" "$PKG"; git clean -fdq -- "$pkgdir/testdata/fuzz/$T"
      elif is_signal_death "$rc"; then
        cls="$(classify_exit "$rc")"; name="${cls##*:}"
        log "KILLED target=$T by $name (exit $rc), no reproducer saved -- OS-level death, not a Go panic; likely a cgo-boundary crash or an OOM kill. The triggering input may be gone (see $LANE/logs/$T.last.log)."
        notify "Fuzz lane signal death: $T" "$(fuzz_report_msg signal-death "$T" "$PKG" "" "killed by $name (exit $rc), no reproducer saved")" high
      else log "run failed without crasher target=$T rc=$rc (see $LANE/logs/$T.last.log)"; notify "Fuzz lane problem: $T" "$HOST rc=$rc without a crasher; see $LANE/logs/$T.last.log"; fi
      break
    fi
    EX=$(grep -o "execs: [0-9]* ([0-9]*/sec)" "$LANE/logs/$T.last.log" | tail -1 | tr -d "()"); NI=$(grep -o "new interesting: [0-9]*" "$LANE/logs/$T.last.log" | tail -1); log "chunk ok target=$T spent=${spent}min ${EX:-execs: n/a} ${NI:-} cores=$(nproc) load1=$(cut -d" " -f1 /proc/loadavg)"
  done
done
log "lane done commit=$COMMIT findings=$FOUND"
notify "Fuzz lane done" "$HOST $REF $COMMIT: $FOUND finding(s) in ~${TOTAL} min"
