#!/usr/bin/env bash
# fuzz-runner.sh — universal continuous-fuzz rotation runner (native go test -fuzz).
# Config: fuzz.conf beside this script, or $FUZZ_CONF. See README.md and the
# Keyorix project doc claude/2026-09-13-universal-corobix-spec.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fuzz-report.sh
source "$SCRIPT_DIR/lib/fuzz-report.sh"
# shellcheck source=lib/exit-classify.sh
source "$SCRIPT_DIR/lib/exit-classify.sh"

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

# --- FUZZ_PREBUILT mode (opt-in via fuzz.conf; default off = unchanged behavior) ---
#
# Line ~413's `go test "$pkg" ... -fuzz=...` recompiles the package's test binary
# on EVERY slice, and discover()'s `go test -list` recompiles again every
# rotation lap — both pay a full build per invocation. FUZZ_PREBUILT=1 builds
# each fuzz-target package's test binary ONCE per commit (`go test -c`), lists
# its targets ONCE from that binary (`<pkg>.test -test.list='^Fuzz'`), and then
# execs that same binary directly for every slice with the identical -test.*
# flags `go test` itself passes — captured for real via `go test -x` against a
# real target (see the Part 2 report for the exact trace):
#   -test.paniconexit0
#   -test.fuzzcachedir=$(go env GOCACHE)/fuzz/<full import path>
#   -test.timeout=10m0s   (go test's own built-in default; empirically
#                          INDEPENDENT of -fuzztime — verified unchanged with
#                          -fuzztime up to 1h30m, because fuzz mode's watchdog
#                          is per-input, not per-invocation)
#   -test.run / -test.fuzz / -test.parallel / -test.fuzztime  (from go test's
#                          own -run/-fuzz/-parallel/-fuzztime)
# Working directory is the package's own source dir (matching go test, which
# cd's there before running) so testdata/fuzz seeds and crasher writes land in
# exactly the same place either mode is used. $GOFLAGS propagates to `go test
# -c` for free via normal environment inheritance — nothing extra to pass.
#
# A build failure on a new commit is logged and NEVER promoted: the rig keeps
# fuzzing (and listing from) the last successfully-built generation and retries
# on the next sync. If no generation has EVER built successfully, discovery and
# execution fall back to the classic go-test path for that cycle — this never
# exits or crash-loops the service over a bad commit.

PREBUILT_ACTIVE_SHA=""   # key of the currently-usable prebuilt generation, or "" if none yet

# prebuilt_dir -> the dedicated binaries root. MUST live outside $(go env
# GOCACHE): Go's own build-cache trimming can evict files under GOCACHE, and a
# prebuilt .test binary disappearing out from under a running rig is exactly
# the failure mode this exists to avoid.
prebuilt_dir() { echo "${PREBUILT_DIR:-${MODULE_DIR}-prebuilt}"; }

# prebuilt_key -> a string that changes exactly when the source does. git SHA
# when MODULE_DIR is a git checkout (every git-mode rig, and most standalone
# ones); otherwise a content hash of go.mod+go.sum+every .go file's bytes
# (portable — no stat(1)/find -printf format differences between BSD and GNU).
prebuilt_key() {
  local sha
  sha="$(git -C "$MODULE_DIR" rev-parse HEAD 2>/dev/null)"
  if [ -n "$sha" ]; then echo "$sha"; return; fi
  find "$MODULE_DIR" -name '*.go' -print0 2>/dev/null | sort -z | xargs -0 cat 2>/dev/null |
    cat "$MODULE_DIR/go.mod" "$MODULE_DIR/go.sum" - 2>/dev/null | sha256sum | cut -d' ' -f1
}

# prebuilt_slug <pkg> -> filesystem-safe name for a package's binary/list files.
prebuilt_slug() { printf '%s' "$1" | tr '/' '_'; }

# env_slug <s> -> s with every character that isn't [A-Za-z0-9_] replaced by
# '_' -- unlike prebuilt_slug (which only replaces '/' and is used to build
# FILESYSTEM paths, where a dot is perfectly legal), this builds a valid bash
# identifier out of an arbitrary Go package import path, which routinely
# contains dots (github.com/..., example.com/...) -- used only for the
# MINIMIZE_TIME_<slug> override variable name below.
env_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }

# prebuilt_build <sha> -> builds every fuzz-target package's test binary + its
# authoritative target list into a STAGING dir, then atomically renames it into
# place only on FULL success. On any package's build/list failure it removes
# the staging dir and returns nonzero — a partial generation is never promoted.
prebuilt_build() {
  local sha="$1" root staging pkg dir slug bin ok=1 tf mb
  root="$(prebuilt_dir)"; staging="$root/.building-$sha"
  rm -rf "$staging"; mkdir -p "$staging"
  : > "$staging/manifest.tsv"
  while IFS='|' read -r dir pkg; do
    [ -n "$pkg" ] || continue
    shopt -s nullglob; tf=("$dir"/*_test.go); shopt -u nullglob
    [ "${#tf[@]}" -gt 0 ] || continue
    grep -qE '^func Fuzz[A-Za-z0-9_]*\(' "${tf[@]}" 2>/dev/null || continue
    slug="$(prebuilt_slug "$pkg")"; bin="$staging/$slug.test"
    # -fuzz='^Fuzz$' at BUILD time is required, not cosmetic: `go test` only sets
    # cmd/go's internal FuzzInstrument (-> -d=libfuzzer, the coverage-counter
    # instrumentation the fuzzing engine's mutation guidance depends on) when
    # -fuzz is non-empty (cmd/go/internal/test/test.go: `if testFuzz != ""`).
    # `go test -c` alone builds a binary that runs -fuzz uninstrumented — proven
    # empirically: it prints "warning: ... not built with coverage
    # instrumentation ... fuzzing will run without coverage guidance" and does
    # dumb/random fuzzing (no corpus growth at all in a real run). The pattern
    # here never needs to match anything real — -c never executes a fuzz
    # session, it only flips this one build-time switch for the whole package.
    if ! go test -c -fuzz='^Fuzz$' -o "$bin" "$pkg" >>"$LOG_DIR/prebuilt-build.log" 2>&1; then
      log "prebuilt: BUILD FAILED for $pkg (sha=$sha) — see $LOG_DIR/prebuilt-build.log"
      ok=0; break
    fi
    if ! "$bin" -test.list='^Fuzz' >"$staging/$slug.targets" 2>>"$LOG_DIR/prebuilt-build.log"; then
      log "prebuilt: -test.list FAILED for $pkg (sha=$sha)"
      ok=0; break
    fi
    printf '%s\t%s\t%s\n' "$pkg" "$slug" "$dir" >>"$staging/manifest.tsv"
    # Coverage-map size for the minimize-time cap (see minimize_cap_for). The
    # binary is already instrumented, so this is one nm pass; a miss just means
    # "unknown" and never fails the generation.
    mb="$(mapsize_of_bin "$bin")"
    [ -n "$mb" ] && printf '%s\t%s\n' "$pkg" "$mb" >>"$staging/mapsizes.tsv"
  done < <(go list -f '{{.Dir}}|{{.ImportPath}}' ./... 2>/dev/null)

  if [ "$ok" -eq 1 ] && [ -s "$staging/manifest.tsv" ]; then
    touch "$staging/.ok"
    rm -rf "${root:?}/${sha:?}"
    mv "$staging" "$root/$sha"
    return 0
  fi
  log "prebuilt: build for sha=$sha did not complete cleanly — discarding staging dir"
  rm -rf "$staging"
  return 1
}

# prebuilt_prune -> keep only the current generation + the most recently-built
# other one. Directory mtimes are set once at `mv`-into-place time (a rename
# does not touch a directory's own mtime on any POSIX filesystem this runs on),
# so "newest by mtime" is exactly "most recently successfully built" — the
# generation this function is called right after building is always #1.
prebuilt_prune() {
  local root old; root="$(prebuilt_dir)"
  [ -d "$root" ] || return 0
  find "$root" -maxdepth 1 -mindepth 1 -type d -name '.building-*' -exec rm -rf {} + 2>/dev/null
  # shellcheck disable=SC2012  # a handful of sibling dirs, no adversarial names expected
  while IFS= read -r old; do
    [ -n "$old" ] && rm -rf "${root:?}/${old:?}"
  done < <(ls -1t "$root" 2>/dev/null | tail -n +3)
}

# prebuilt_ensure -> makes PREBUILT_ACTIVE_SHA name a generation with a valid
# .ok marker for the CURRENT source. Cheap (no build) when nothing changed.
prebuilt_ensure() {
  local sha root; sha="$(prebuilt_key)"; root="$(prebuilt_dir)"
  if [ -f "$root/$sha/.ok" ]; then
    PREBUILT_ACTIVE_SHA="$sha"
    return 0
  fi
  log "prebuilt: building generation for sha=$sha"
  if prebuilt_build "$sha"; then
    PREBUILT_ACTIVE_SHA="$sha"
    prebuilt_prune
    return 0
  fi
  if [ -n "$PREBUILT_ACTIVE_SHA" ]; then
    log "prebuilt: keeping previous generation sha=$PREBUILT_ACTIVE_SHA — will retry sha=$sha next sync"
  else
    log "prebuilt: no generation has ever built successfully — falling back to go test for this cycle"
  fi
  return 1
}

# prebuilt_list_targets -> "pkg|Func" lines from PREBUILT_ACTIVE_SHA's manifest.
prebuilt_list_targets() {
  local root pkg slug dir fn
  root="$(prebuilt_dir)/$PREBUILT_ACTIVE_SHA"
  [ -f "$root/manifest.tsv" ] || return 0
  while IFS=$'\t' read -r pkg slug dir; do
    [ -n "$pkg" ] || continue
    while IFS= read -r fn; do
      [ -n "$fn" ] && printf '%s|%s\n' "$pkg" "$fn"
    done < "$root/$slug.targets"
  done < "$root/manifest.tsv"
}

# prebuilt_pkg_info <pkg> -> "slug<TAB>dir" from PREBUILT_ACTIVE_SHA's manifest,
# or empty if <pkg> isn't in it.
prebuilt_pkg_info() {
  awk -F'\t' -v p="$1" '$1==p {print $2"\t"$3; exit}' "$(prebuilt_dir)/$PREBUILT_ACTIVE_SHA/manifest.tsv" 2>/dev/null
}

# discover_targets -> discover() itself when FUZZ_PREBUILT is off (the
# unchanged default); otherwise ensure a prebuilt generation is current and
# list from it, falling back to discover() for one cycle if no generation has
# ever built successfully.
discover_targets() {
  if [ "${FUZZ_PREBUILT:-0}" = 1 ]; then
    if prebuilt_ensure; then
      prebuilt_list_targets
      return
    fi
  fi
  discover
}

# --- Minimize-time cap for heavy coverage maps (opt-in via MINIMIZE_CAP=on) ---
#
# Go's fuzz engine minimizes every new interesting input for up to 60s by
# default, and each minimization step re-scans the WHOLE coverage-counter map.
# A package that transitively imports a lot (keyorix internal/core, server/http,
# ...) has a 250-480 KB map, and on those packages minimization measurably
# stalls the run: 19% and 51% of wall time on two pure internal/core targets,
# 67% on the stateful HTTP sequence fuzzer. Capping it at MINIMIZE_CAP_VALUE
# (default 100x = 100 attempts) removed the stall entirely on the pure targets
# and cut the stateful one to 30%, with byte-identical coverage under the
# default, 100x and 0 on all three (Keyorix project doc
# claude/2026-09-23-coverage-map-leaf-package-ab-results.md). Small-map
# packages (csvsafe ~5 KB, netutil ~18-43 KB) showed no stall, so the cap is
# applied only above MINIMIZE_CAP_THRESHOLD bytes of map.
#
# The map size is MEASURED, never hand-maintained: it is the distance between
# the linker symbols internal/fuzz._counters and internal/fuzz._ecounters in an
# INSTRUMENTED test binary (`go test -c -fuzz=...`; a plain -c build has none).
# FUZZ_PREBUILT=1 records it while building each generation (mapsizes.tsv next
# to manifest.tsv, free: the binary is already there). Otherwise it is measured
# on first use per (source key, package), cached under $STATE_DIR/mapsize/, so
# it tracks every commit on its own. Unknown size (build or nm failure) = no
# cap, logged: this must never stop the rig fuzzing.

# mapsize_of_bin <test-binary> -> coverage-map bytes, or nothing if the binary
# has no fuzz counters (uninstrumented) or can't be read.
mapsize_of_bin() {
  local a b
  read -r a b < <(go tool nm "$1" 2>/dev/null | awk '
    $NF=="internal/fuzz._counters"  {a=$1}
    $NF=="internal/fuzz._ecounters" {b=$1}
    END {if (a!="" && b!="") print a, b}')
  [ -n "${a:-}" ] && [ -n "${b:-}" ] || return 0
  echo $(( 16#$b - 16#$a ))
}

# pkg_map_bytes <pkg> -> the package's coverage-map bytes, or nothing if unknown.
pkg_map_bytes() {
  local pkg="$1" v key slug dir tmp
  if [ "${FUZZ_PREBUILT:-0}" = 1 ] && [ -n "$PREBUILT_ACTIVE_SHA" ]; then
    v="$(awk -F'\t' -v p="$pkg" '$1==p {print $2; exit}' "$(prebuilt_dir)/$PREBUILT_ACTIVE_SHA/mapsizes.tsv" 2>/dev/null)"
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  key="$(prebuilt_key)"; slug="$(prebuilt_slug "$pkg")"
  dir="$STATE_DIR/mapsize/$key"
  if [ -f "$dir/$slug" ]; then
    v="$(cat "$dir/$slug" 2>/dev/null)"; [ "$v" = "-" ] || echo "$v"; return 0
  fi
  mkdir -p "$dir"; tmp="$dir/.$slug.test.$$"
  v=""
  if go test -c -fuzz='^Fuzz$' -o "$tmp" "$pkg" >>"$LOG_DIR/mapsize-build.log" 2>&1; then
    v="$(mapsize_of_bin "$tmp")"
  fi
  rm -f "$tmp"
  # "-" caches an unknown result too, so a package that won't build instrumented
  # isn't rebuilt on every slice of this commit.
  echo "${v:--}" > "$dir/$slug"
  # Keep only this key's cache (plus the one just written); old commits pile up otherwise.
  find "$STATE_DIR/mapsize" -mindepth 1 -maxdepth 1 -type d ! -name "$key" -exec rm -rf {} + 2>/dev/null
  [ -n "$v" ] && echo "$v"
  return 0
}

# minimize_cap_for <pkg> -> the -fuzzminimizetime value to pass for <pkg>, or
# nothing (keep Go's default). Pure decision given pkg_map_bytes.
#
# A per-package override wins over the computed default: MINIMIZE_TIME_<slug>
# (env_slug's identifier-safe form of pkg -- e.g. pkg
# github.com/keyorixhq/keyorix/server/http becomes
# MINIMIZE_TIME_github_com_keyorixhq_keyorix_server_http=0 or =10x; NOT the
# same slug prebuilt_slug/pkg_map_bytes use for filesystem paths, since a
# valid bash variable name can't contain the dots a Go import path routinely
# has). This exists because the default,
# uniform 100x was measured on PURE targets only (2026-09-23 A/B doc); the
# one STATEFUL target measured there (server/http's HTTP sequence fuzzer)
# only dropped from 66.7% to 30.3% stalled at 100x -- a stateful, heavy
# package may need a different cap (10x, or 0 to disable minimization
# entirely) once a real rig's numbers are in, without changing the global
# default every other (pure) package still benefits from. Still gated on
# MINIMIZE_CAP=on -- this overrides WHICH value is used, not whether the
# feature is on at all.
minimize_cap_for() {
  [ "${MINIMIZE_CAP:-off}" = on ] || return 0
  local pkg="$1" ov bytes
  ov="MINIMIZE_TIME_$(env_slug "$pkg")"
  if [ -n "${!ov:-}" ]; then
    echo "${!ov}"
    return 0
  fi
  bytes="$(pkg_map_bytes "$pkg")"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  [ "$bytes" -gt "${MINIMIZE_CAP_THRESHOLD:-100000}" ] && echo "${MINIMIZE_CAP_VALUE:-100x}"
  return 0
}

# --- Concurrent-target mode (opt-in via CONCURRENT_TARGETS=on) ---------------
#
# Some targets are fundamentally exec-cost-bound (real DB writes, PBKDF2,
# fsync per iteration): raising -parallel within their OWN go-test process
# barely moves execs/s, because the bottleneck is the shared DB
# handle/file/KDF path every worker goroutine serializes on, not CPU. On a
# multi-core rig that leaves cores idle while one slow target's single
# go-test process fuzzes alone for its whole slice. When on, the runner uses
# the exec-rate history it already records (measured_exec_rate, the same
# history resolve_duration/is_saturated read) to recognize a target as
# "slow", and if the CURRENT rotation target is slow, runs it alongside up
# to CONCURRENT_MAX_TARGETS-1 OTHER slow targets as separate go-test
# processes for the same slice, instead of one at a time.
#
# Grouping is deliberately CONTIGUOUS-ONLY: a group is TARGETS[i..i+k), never
# an arbitrary scan-and-pick across the whole rotation. This keeps "advance i
# by the group size" a correct, in-bounds forward step (the caller's
# resume-position bookkeeping is unaffected by which OTHER targets happen to
# be slow elsewhere in the list), and it never wraps past the end of
# TARGETS -- a group straddling the wrap would re-enter index 0's
# sync/corpus-sync/rediscovery reset mid-group, which this avoids entirely
# by capping the window at len(TARGETS). The tradeoff: two slow targets that
# aren't adjacent in the (sorted) target list are never grouped together.
# That is a real limitation of this v1, not an oversight -- broadening it to
# a non-contiguous pick would need the caller to track and skip specific
# consumed indices out of order instead of a single forward advance, which
# is meaningfully more state to get right for a first cut behind a
# default-off flag.
#
# A target with NO measured rate yet (0, "unknown") is never treated as
# slow -- only a CONFIRMED-slow target (from a prior run) can trigger
# grouping, so a brand-new target's first run is never affected.

# is_slow_target <fn> -> 0 (slow) iff fn has a nonzero measured exec rate
# below CONCURRENT_SLOW_THRESHOLD execs/s; 1 otherwise (including "unknown").
is_slow_target() {
  local fn="$1" rate
  rate="$(measured_exec_rate "$fn")"
  [ "$rate" -gt 0 ] 2>/dev/null || return 1
  [ "$rate" -lt "${CONCURRENT_SLOW_THRESHOLD:-20}" ]
}

# pick_group_size <i> -> how many of TARGETS[i..] (>= 1) to run together this
# round. 1 (no grouping) unless CONCURRENT_TARGETS=on, TARGETS[i] is itself
# slow, and one or more IMMEDIATELY FOLLOWING entries are also slow (see the
# contiguous-only rationale above), up to CONCURRENT_MAX_TARGETS (default 3,
# floored at 2 -- a "group" of 1 is a no-op by construction and isn't a
# valid request). Reads the global TARGETS array set up by main().
pick_group_size() {
  local i="$1" n="${#TARGETS[@]}" cap="${CONCURRENT_MAX_TARGETS:-3}" j size=1
  [ "${CONCURRENT_TARGETS:-off}" = on ] || { echo 1; return; }
  [ "$cap" -ge 2 ] || cap=2
  is_slow_target "${TARGETS[$i]##*|}" || { echo 1; return; }
  for (( j = i + 1; j < n && size < cap; j++ )); do
    is_slow_target "${TARGETS[$j]##*|}" || break
    size=$(( size + 1 ))
  done
  echo "$size"
}

# run_target_group <i> <gsize> -> runs TARGETS[i..i+gsize) for this
# rotation round: each member's own resolve_duration/minimize_cap_for
# (targets in a group are not assumed to share a duration or minimize-time
# override), launched concurrently as separate go-test processes when
# gsize>1 (exactly run_slice's existing invocation, just backgrounded and
# waited on instead of run serially -- same per-target log file, same
# fuzzcachedir, same everything else), then applies the SAME crash-check +
# reverify + record_saturation handling the runner has always done, once
# per group member. Does NOT touch POS_FILE or i -- the caller resolves and
# persists the group size BEFORE calling this, so a kill mid-group still
# resumes at the correct next position exactly as a kill mid-single-target
# slice always has.
run_target_group() {
  local i="$1" gsize="$2" gi gentry gpkg gfn gdur gmt gmbytes d idx rc wkmsg
  local -a group_fns=() pids=() offs=()
  for (( gi = 0; gi < gsize; gi++ )); do
    group_fns+=("${TARGETS[$((i + gi))]}")
  done
  [ "$gsize" -gt 1 ] && log "=== concurrent group (${gsize}): ${group_fns[*]} ==="
  for gentry in "${group_fns[@]}"; do
    gpkg="${gentry%%|*}"; gfn="${gentry##*|}"
    gdur="$(resolve_duration "$gfn")"
    gmt=""
    if [ "$MINIMIZE_CAP" = on ]; then
      gmbytes="$(pkg_map_bytes "$gpkg")"
      [[ "$gmbytes" =~ ^[0-9]+$ ]] && gmt="$(minimize_cap_for "$gpkg")"
    fi
    [ "$gsize" -eq 1 ] && log "=== fuzzing $gfn ($gpkg) for $gdur${gmt:+ minimizetime=$gmt (map ${gmbytes}B)} ==="
    offs+=("$(wc -c < "$LOG_DIR/${gfn}.log" 2>/dev/null || echo 0)")
    # Freeze instrumentation: fuzzutil's stall monitor appends one line per detected
    # process freeze to this file (see stall_summary). Truncated per slice.
    mkdir -p "$LOG_DIR/stalls"; : >"$LOG_DIR/stalls/${gfn}.stalls"
    ( FUZZ_STALL_LOG="$LOG_DIR/stalls/${gfn}.stalls" run_slice "$gpkg" "$gfn" "$gdur" "$gmt" >>"$LOG_DIR/${gfn}.log" 2>&1 ) &
    pids+=("$!")
  done
  for idx in "${!pids[@]}"; do
    wait "${pids[$idx]}"; rc=$?
    gentry="${group_fns[$idx]}"; gpkg="${gentry%%|*}"; gfn="${gentry##*|}"
    d="$(find . -type d -path "*/testdata/fuzz/$gfn" 2>/dev/null | head -1)"
    if is_signal_death "$rc"; then
      log "$gfn ($gpkg): process died by $(classify_exit "$rc" | cut -d: -f3) (exit $rc) — OS-level kill, not a Go panic. Likely a crash reached across a cgo boundary, or an OOM kill."
    fi
    if [ -n "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
      if [ "${REVERIFY_CRASH:-on}" = on ] && ! reproducer_reverifies "$gfn" "$gpkg"; then
        log "$gfn: reproducer did NOT re-fail on ${REVERIFY_RUNS:-1}x replay — transient worker death, not alerting (local copy kept in $FINDINGS_DIR/$gfn)"
        quarantine_unverified "$gfn"
      else
        handle_crash "$gfn" "$gpkg" "$rc"
      fi
    elif is_signal_death "$rc"; then
      report_signal_death "$gfn" "$gpkg" "$rc"
    elif wkmsg="$(worker_killed_no_crash_message "$gfn" "${offs[$idx]:-0}")"; then
      report_worker_killed_no_crash "$gfn" "$gpkg" "$wkmsg"
    elif [ "$rc" -ne 0 ]; then
      report_nonrepro_exit "$gfn" "$rc" "${offs[$idx]:-0}"
    fi
    record_saturation "$gfn"
    stall_summary "$gfn"
  done
}

# seed_failure_message <fn> <offset> -> prints the first Go failure line and returns 0 when the
# slice output appended to $LOG_DIR/<fn>.log after byte <offset> shows the fuzz target failing on
# its own SEED corpus ("failure while testing seed corpus entry"). That failure is deterministic
# (it replays every rotation), so it means the harness or target is broken, NOT infra/timeout.
# Only this slice's output is examined: the log is append-only across rotations.
seed_failure_message() {
  local fn="$1" off="${2:-0}" out
  out="$(tail -c +"$((off + 1))" "$LOG_DIR/${fn}.log" 2>/dev/null)"
  printf '%s\n' "$out" | grep -q 'failure while testing seed corpus entry' || return 1
  printf '%s\n' "$out" | grep -m1 -E '^[[:space:]]+[A-Za-z0-9_./-]+\.go:[0-9]+:' | sed -E 's/^[[:space:]]+//' | cut -c1-300
  return 0
}

# report_nonrepro_exit <fn> <rc> <offset>: a non-zero exit with no reproducer file. A seed-corpus
# failure is alerted (once per target per day, so a permanently broken target cannot spam);
# anything else keeps the old "infra/timeout, logged not alerted" behaviour.
report_nonrepro_exit() {
  local fn="$1" rc="$2" off="${3:-0}" msg stamp today
  if msg="$(seed_failure_message "$fn" "$off")"; then
    log "$fn: SEED CORPUS FAILURE (exit $rc) — deterministic, harness/target broken, not infra: ${msg:-no failure line captured}"
    today="$(date -u +%Y-%m-%d)"
    stamp="${STATE_DIR:-.}/seedfail-${fn}"
    if [ "$(cat "$stamp" 2>/dev/null)" != "$today" ]; then
      printf '%s\n' "$today" > "$stamp" 2>/dev/null || true
      notify "HARNESS BROKEN: $fn fails on its own seed corpus on $(hostname) — ${msg:-see $LOG_DIR/${fn}.log}"
    fi
  else
    log "$fn exited $rc with no reproducer — infra/timeout, logged not alerted"
  fi
}

# report_signal_death <fn> <pkg> <rc>: go test -fuzz was killed outright by a signal and left no
# testdata/fuzz reproducer. Unlike report_nonrepro_exit's seed-corpus-or-silent-infra split, this
# is never downgraded to silent — an OS-level kill (not a Go panic) with nothing saved is the one
# case where the triggering input can be lost entirely if no one looks at this run. Detect-only:
# this does NOT bisect the corpus to find which input caused it (see lib/exit-classify.sh's header
# for why not — that would mean one subprocess per fuzz execution, the opposite of what makes
# go test -fuzz fast).
report_signal_death() {
  local fn="$1" pkg="$2" rc="$3" cls name
  cls="$(classify_exit "$rc")"; name="${cls##*:}"
  log "$fn ($pkg): KILLED BY $name (exit $rc) with NO testdata/fuzz reproducer saved — OS-level death, not a Go panic; likely a cgo-boundary crash or an OOM kill. The triggering input may be gone; see $LOG_DIR/${fn}.log."
  notify "$(fuzz_report_msg "signal-death" "$fn" "$pkg" "" "killed by $name (exit $rc), no reproducer saved")"
}

# worker_killed_no_crash_message <fn> <offset> -> prints Go's own explanation line and returns 0
# when the slice output appended to $LOG_DIR/<fn>.log after byte <offset> shows internal/fuzz's
# own "no crash will be recorded" message. go test -fuzz's coordinator deliberately declines to
# save a reproducer when a worker is killed by a signal it doesn't consider crash-indicative --
# SIGKILL, SIGHUP -- because the kernel OOM killer or an external supervisor, not the fuzzed
# input, is the likely cause (internal/fuzz/worker.go's isCrashSignal: SIGILL/SIGTRAP/SIGABRT/
# SIGBUS/SIGFPE/SIGSEGV/SIGPIPE DO get a reproducer saved as an ordinary crash; SIGKILL/SIGHUP/
# anything else does NOT). This is the real version of the gap report_signal_death only partly
# covers: under NORMAL (non-FUZZ_PREBUILT) go test -fuzz, the go command's own test driver
# absorbs a worker's SIGKILL into a clean rc=1 at the shell level -- is_signal_death never sees
# rc>128 for this -- so this is the one place a genuine OOM-killed or externally-killed cgo-
# boundary worker is actually caught instead of falling through to report_nonrepro_exit's silent
# "infra/timeout, logged not alerted" branch. Only this slice's output is examined, same
# convention as seed_failure_message.
worker_killed_no_crash_message() {
  local fn="$1" off="${2:-0}" out
  out="$(tail -c +"$((off + 1))" "$LOG_DIR/${fn}.log" 2>/dev/null)"
  printf '%s\n' "$out" | grep -q 'no crash will be recorded' || return 1
  printf '%s\n' "$out" | grep -m1 'no crash will be recorded' | sed -E 's/^[[:space:]]+//' | cut -c1-300
  return 0
}

# report_worker_killed_no_crash <fn> <pkg> <msg>: see worker_killed_no_crash_message above.
# Never downgraded to silent, for the same reason report_signal_death isn't: the triggering
# input can be gone entirely, and this is specifically the case Go itself chose not to keep it.
report_worker_killed_no_crash() {
  local fn="$1" pkg="$2" msg="$3"
  log "$fn ($pkg): $msg — go's own fuzz coordinator declined to save a reproducer (not treated as crash-indicative, e.g. SIGKILL/SIGHUP); likely an OOM kill or external supervisor. The triggering input may be gone; see $LOG_DIR/${fn}.log."
  notify "$(fuzz_report_msg "signal-death" "$fn" "$pkg" "" "$msg; no reproducer saved")"
}

# stall_summary <fn> -> after a slice, summarise the freezes the target's process saw
# ($LOG_DIR/stalls/<fn>.stalls, lines "<ts> pid=N exe=X frozen=<go duration>"): one log line
# and one row in $LOG_DIR/stalls.tsv (ts fn count max_s total_s) so freeze frequency per box
# can be aggregated. Silent when there were none. Never fails the run.
stall_summary() {
  local f="$LOG_DIR/stalls/$1.stalls" row
  [ -s "$f" ] || return 0
  row="$(grep -ao 'frozen=[0-9hmsµ.]*' "$f" | awk -v fn="$1" '
    function secs(d,   h,m,s,ms,t) { t=0
      if (match(d,/[0-9.]+h/))  { t+=substr(d,RSTART,RLENGTH-1)*3600 }
      if (match(d,/[0-9.]+m[^s]/)) { t+=substr(d,RSTART,RLENGTH-2)*60 }
      if (match(d,/[0-9.]+ms/)) { t+=substr(d,RSTART,RLENGTH-2)/1000; return t }
      if (match(d,/[0-9.]+s/))  { t+=substr(d,RSTART,RLENGTH-1) }
      return t }
    { sub(/^frozen=/,""); v=secs($0); n++; tot+=v; if (v>mx) mx=v }
    END { if (n) printf "%s\t%d\t%.1f\t%.1f", fn, n, mx, tot }')" || return 0
  [ -n "$row" ] || return 0
  log "stalls: ${row//$'\t'/ } (fn count max_s total_s)"
  printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$row" >>"$LOG_DIR/stalls.tsv" 2>/dev/null || true
}

# run_slice <pkg> <fn> <dur> -> exactly today's `go test ... -fuzz=...`
# invocation unless FUZZ_PREBUILT=1 has a usable generation covering <pkg>, in
# which case it execs that generation's prebuilt binary directly with the
# identical -test.* flags (see the header comment above discover()'s
# FUZZ_PREBUILT section) — same corpus cache dir, same crasher path.
run_slice() {
  local pkg="$1" fn="$2" dur="$3" info slug dir gocache mt
  local -a extra=()
  # Optional 4th arg: the minimize cap already resolved by the caller (main
  # resolves it once so it can log the decision); empty = Go's default.
  mt="${4:-}"
  if [ "${FUZZ_PREBUILT:-0}" = 1 ] && [ -n "$PREBUILT_ACTIVE_SHA" ]; then
    info="$(prebuilt_pkg_info "$pkg")"
    if [ -n "$info" ]; then
      slug="${info%%$'\t'*}"; dir="${info#*$'\t'}"
      gocache="$(go env GOCACHE)"
      [ -n "$mt" ] && extra=(-test.fuzzminimizetime="$mt")
      ( cd "$dir" && exec "$(prebuilt_dir)/$PREBUILT_ACTIVE_SHA/$slug.test" \
          -test.paniconexit0 \
          -test.fuzzcachedir="$gocache/fuzz/$pkg" \
          -test.timeout=10m0s \
          -test.run='^$' \
          -test.fuzz="^${fn}\$" \
          -test.parallel="$PARALLEL" \
          -test.fuzztime="$dur" \
          ${extra[@]+"${extra[@]}"} )
      return $?
    fi
  fi
  [ -n "$mt" ] && extra=(-fuzzminimizetime="$mt")
  go test "$pkg" -run='^$' -fuzz="^${fn}\$" -parallel="$PARALLEL" -fuzztime="$dur" ${extra[@]+"${extra[@]}"}
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
  # Also mirror into the trusted Mac-side puller's expected layout
  # ($HOME/lane/crashers/<target>/<hash>/ — see deploy/mac/crasher-pull.sh
  # and its README). The puller never trusts this directory's NAME as a
  # hash — it independently manifests the content on both ends and
  # compares those — so it only needs to look like one (fuzz-lane.sh's own
  # convention: sha256 of the concatenated reproducer bytes, cut to 12
  # hex chars). Best-effort and non-fatal: a mirror failure must never
  # affect $dest above, which is the one copy everything else here
  # depends on.
  if [ -n "$src" ]; then
    local lane_hash lane_dest
    lane_hash="$(cat "$src"/* 2>/dev/null | sha256sum | cut -c1-12)"; [ -n "$lane_hash" ] || lane_hash="$ts"
    lane_dest="${LANE_CRASHERS_DIR:-$HOME/lane/crashers}/$fn/$lane_hash"
    # shellcheck disable=SC2015  # intended: log on failure of EITHER step, not if-then-else
    mkdir -p "$lane_dest" 2>/dev/null && cp -a "$src"/. "$lane_dest"/ 2>/dev/null \
      || log "lane/crashers mirror failed for $fn (non-fatal; $dest is unaffected)"
  fi
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
      notify "$(fuzz_report_msg "public PR" "$fn" "$pkg" "$dest")"
      ;;
    private)
      log "CRASH $fn ($pkg) rc=$rc — pushing to private $CORPUS_REPO (local copy -> $dest)"
      push_crasher_private "$fn" "$pkg" "$ts" "$src"
      notify "$(fuzz_report_msg "private" "$fn" "$pkg" "$dest" "pushed to $CORPUS_PROJECT")"
      ;;
    issue)
      # PUBLIC GitHub issue as a repro POINTER — never the raw crashing input
      # (that stays local, and in the private CORPUS_REPO if configured), so
      # opening an issue on a public repo does not itself disclose the 0-day.
      #
      # Uses the REST API (`gh api`), never `gh issue create`/`gh issue list`:
      # those go through gh's GraphQL path, which queries fields (e.g.
      # repository.defaultBranchRef) outside what a fine-grained PAT scoped
      # to just Issues: write grants — confirmed 2026-11-18, `gh issue create`
      # failed outright with "Resource not accessible by personal access
      # token" against the least-privilege token this mode is meant to run
      # with. REST has no such requirement.
      #
      # De-duped by title + the "vcd-auto" label: a target that keeps
      # crashing across rotations (same bug, new random input each time)
      # gets ONE issue with a "seen again" comment per repeat, not a fresh
      # issue every time — REVERIFY_CRASH only filters a single slice's
      # flakiness, not repeats across later rotations.
      log "CRASH $fn ($pkg) rc=$rc — opening a GitHub issue (repro pointer; raw input kept local -> $dest)"
      if command -v gh >/dev/null; then
        # shellcheck disable=SC2016  # single-quoted printf FORMAT: %s are printf specifiers, backticks are literal markdown
        body="$(printf 'A fuzz run for `%s` in `%s` exited non-zero and produced a reproducer (rc=%s, %s).\n\nReproduce on a checkout at this commit:\n\n```\ngo test -run='\''^%s$'\'' %s\n```\n\nThe crashing input is intentionally NOT included here (disclosure safety): it is on the rig under FINDINGS_DIR%s. Set ISSUE_INCLUDE_LOG=1 on the rig to attach a scrubbed log tail.' \
          "$fn" "$pkg" "$rc" "$ts" "$fn" "$pkg" "$([ -n "${CORPUS_REPO:-}" ] && printf ', and in the private corpus repo')")"
        if [ "${ISSUE_INCLUDE_LOG:-0}" = "1" ]; then
          body="${body}"$'\n\nLog tail:\n\n```\n'"$(tail -n 20 "$LOG_DIR/${fn}.log" 2>/dev/null | tr -d '`')"$'\n```'
        fi
        # ISSUE_REPO targets a specific repo (REQUIRED for REST — unlike
        # `gh issue create`, the REST endpoint can't infer it from the
        # module checkout's remote). Falls back to parsing $GIT_REMOTE's
        # URL (a local git command, not a GitHub API call, so it works
        # regardless of token scope) only when ISSUE_REPO is unset.
        issue_repo="${ISSUE_REPO:-$(git remote get-url "${GIT_REMOTE:-origin}" 2>/dev/null \
          | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')}"
        if [ -z "$issue_repo" ]; then
          log "issue mode: could not determine ISSUE_REPO (set it explicitly) — reproducer kept local -> $dest"
        else
          title="fuzz(crash): $fn"
          existing="$(gh api "repos/$issue_repo/issues?state=all&labels=vcd-auto&per_page=100" \
            --jq ".[] | select(.title == \"$title\") | .number" 2>/dev/null | head -1)"
          if [ -n "$existing" ]; then
            gh api -X POST "repos/$issue_repo/issues/$existing/comments" -f body="Seen again ($ts, rc=$rc).

$body" >/dev/null 2>&1 \
              || log "issue comment failed (non-fatal) on #$existing — reproducer kept local -> $dest"
          else
            gh api -X POST "repos/$issue_repo/issues" -f title="$title" -f body="$body" -f "labels[]=vcd-auto" \
              >/dev/null 2>&1 \
              || log "issue create failed (non-fatal) on $issue_repo — reproducer kept local -> $dest"
          fi
        fi
      else
        log "gh not available — cannot open issue; reproducer kept local -> $dest"
      fi
      notify "$(fuzz_report_msg "issue" "$fn" "$pkg")"   # no path arg — disclosure safety
      ;;
    *)
      log "CRASH $fn ($pkg) rc=$rc — reproducer(s) -> $dest (mode=local, NOT published)"
      notify "$(fuzz_report_msg "local" "$fn" "$pkg" "$dest")"
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
  # Prebuilt-test-binary mode (off by default — see the FUZZ_PREBUILT section
  # above discover()). PREBUILT_DIR defaults to a sibling of MODULE_DIR, same
  # convention as STATE_DIR/LOG_DIR/FINDINGS_DIR, and MUST stay outside GOCACHE.
  : "${FUZZ_PREBUILT:=0}"; : "${PREBUILT_DIR:=$MODULE_DIR-prebuilt}"
  # Minimize-time cap for heavy coverage maps (off = unchanged behavior; see the
  # section above minimize_cap_for).
  : "${MINIMIZE_CAP:=off}"; : "${MINIMIZE_CAP_VALUE:=100x}"; : "${MINIMIZE_CAP_THRESHOLD:=100000}"
  # Concurrent-target mode (off = unchanged behavior; see the section above
  # is_slow_target). CONCURRENT_MAX_TARGETS floors at 2 inside pick_group_size.
  : "${CONCURRENT_TARGETS:=off}"; : "${CONCURRENT_SLOW_THRESHOLD:=20}"; : "${CONCURRENT_MAX_TARGETS:=3}"
  [ -n "${CRASH_MODE:-}" ] && echo "fuzz-runner: CRASH_MODE is deprecated — rename it to REPORT_MODE in fuzz.conf (honored for now)" >&2
  local eff; eff="$(effective_report_mode)"
  [ "$eff" = "${REPORT_MODE}" ] || echo "fuzz-runner: report mode $REPORT_MODE -> $eff for standalone module (disclosure safety)" >&2
  REPORT_MODE="$eff"
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$FINDINGS_DIR"
  CONF_HASH="$(sha256sum "$CONF" | cut -d' ' -f1)"
  cd "$MODULE_DIR" || { echo "fuzz-runner: MODULE_DIR not found: $MODULE_DIR" >&2; exit 1; }

  # Shared-module pin drift, warning-only: a target module fuzzing a version of a
  # library keyorix no longer ships (or ships a different version of) is silent
  # otherwise — this is what missed digitorus/pkcs7 drifting ~3 years stale.
  # check-shared-pins.sh only ships to rigs that deploy/deploy.sh has copied it to
  # (deploy.sh scps scripts/check-shared-pins.sh + scripts/pin-drift-allowlist.tsv
  # alongside the runner) — a rig without it just logs that once and moves on;
  # this is advisory, never a reason to refuse to fuzz.
  if [ -x "$SCRIPT_DIR/scripts/check-shared-pins.sh" ]; then
    "$SCRIPT_DIR/scripts/check-shared-pins.sh" --warn-only "$MODULE_DIR" 2>&1 |
      while IFS= read -r drift_line; do log "drift-guard: $drift_line"; done
  else
    log "drift-guard: scripts/check-shared-pins.sh not deployed here — skipping (advisory only)"
  fi

  [ "$SOURCE_MODE" = "git" ] && sync_main
  mapfile -t TARGETS < <(discover_targets | sort | filter_targets)
  [ "${#TARGETS[@]}" -gt 0 ] || { log "no fuzz targets discovered under $MODULE_DIR"; exit 1; }
  log "discovered ${#TARGETS[@]} target(s); mode=$SOURCE_MODE/$REPORT_MODE default=$DEFAULT_FUZZTIME corpus_sync=$CORPUS_SYNC"

  local POS_FILE="$STATE_DIR/rotation-pos" i=0 s
  if [ -r "$POS_FILE" ]; then s="$(cat "$POS_FILE" 2>/dev/null || echo 0)"; [[ "$s" =~ ^[0-9]+$ ]] && i=$(( s % ${#TARGETS[@]} )); fi

  local gsize
  while true; do
    if [ "$(sha256sum "$CONF" | cut -d' ' -f1)" != "$CONF_HASH" ]; then
      log "fuzz.conf changed — reloading (resumes from rotation-pos)"; exec "$0" "$@"
    fi
    if [ "$i" -eq 0 ]; then
      [ "$SOURCE_MODE" = "git" ] && sync_main
      sync_corpus
      saturation_report
      mapfile -t NEW < <(discover_targets | sort | filter_targets)
      if [ "${#NEW[@]}" -gt 0 ] && [ "${NEW[*]}" != "${TARGETS[*]}" ]; then
        log "target set changed (${#TARGETS[@]} -> ${#NEW[@]}) — reloading"; exec "$0" "$@"
      fi
    elif [ "$SOURCE_MODE" = "git" ]; then
      sync_main
    fi
    gsize="$(pick_group_size "$i")"
    echo "$(( (i+gsize) % ${#TARGETS[@]} ))" > "$POS_FILE"
    run_target_group "$i" "$gsize"
    i=$(( (i+gsize) % ${#TARGETS[@]} ))
  done
}

CONF="${FUZZ_CONF:-$SCRIPT_DIR/fuzz.conf}"
[ -n "${FUZZ_RUNNER_LIB:-}" ] && return 0 2>/dev/null   # test hook: source for functions only
main "$@"
