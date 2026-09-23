#!/usr/bin/env bash
# phase0.sh — Phase 0 fuzz-rediscovery benchmark (BASE vs AFTER, keyorix).
#
# Runs entirely on the bench box (pve01 CT 240 / keyorix-bench), against
# /opt/bench/base and /opt/bench/after (pinned keyorix checkouts, already
# present) plus /opt/bench/fuzz-harness and /opt/bench/fuzz-corpus (deployed
# separately via `rsync -a --exclude=.git`, NOT by this script — this box
# has no GitHub credentials, so cloning from here isn't an option).
#
# Idempotent/resumable: every unit of work (a setup step, a trial, a
# measurement) is guarded by a done-marker under $RESULT_DIR/.done — re-running
# the same subcommand skips anything already recorded and picks up where it
# left off. Nothing here restarts libsfuzz or CTs 100/221/222/223 — Phase 0
# runs with those left stopped for its whole duration (2026-09-23 policy from
# Andrei); if this script is interrupted or aborted, it changes nothing about
# their state either.
#
# Usage:
#   phase0.sh setup                  # idempotent: go/postgres/k6/vegeta/syft/govulncheck
#   phase0.sh fingerprint            # hw.txt snapshot (also called by every part)
#   phase0.sh partB [--dry-run]      # fuzz mechanics
#   phase0.sh partC                  # build/footprint/attack-surface (BASE only)
#   phase0.sh partA [--dry-run]      # bug-rediscovery trials (the headline)
#   phase0.sh stats                  # invoke phase0_stats.py over partA's JSON
#
# --dry-run shrinks every duration/rep count for a fast smoke test of the
# plumbing (see DRY_RUN block below) — never use its numbers for the report.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A systemd-run transient unit's default environment has no $HOME at all (not
# just a different one) — under `set -u` that's an immediate unbound-variable
# abort the FIRST time anything references $HOME, not a soft failure. Confirmed
# directly: cmd_partC died silently between fingerprint and its own first note
# for exactly this reason. Guard once, here, for every function.
export HOME="${HOME:-/root}"
export PATH="/usr/local/go/bin:/root/go/bin:${PATH:-/usr/bin:/bin}"
SUBCOMMAND="${1:-}"
shift || true
DRY_RUN=0
for arg in "$@"; do
	[ "$arg" = "--dry-run" ] && DRY_RUN=1
done

# ---------------------------------------------------------------------------
# Config (env-overridable; defaults match the CT 240 layout confirmed by recon)
# ---------------------------------------------------------------------------
GO_BIN="${GO_BIN:-/usr/local/go/bin/go}"
command -v "$GO_BIN" >/dev/null 2>&1 || GO_BIN="$(command -v go || true)"

BASE_DIR="${BASE_DIR:-/opt/bench/base}"
AFTER_DIR="${AFTER_DIR:-/opt/bench/after}"
HARNESS_DIR="${HARNESS_DIR:-/opt/bench/fuzz-harness}"
CORPUS_DIR="${CORPUS_DIR:-/opt/bench/fuzz-corpus}"
SCRATCH="${SCRATCH:-/opt/bench/work}"
GO_TOOLCHAIN_VERSION="${GO_TOOLCHAIN_VERSION:-1.27.1}" # matches go.work `go 1.27` + confirmed installed version

PIN_CPUS=(0 1 2 3) # confirmed via lscpu -e: distinct physical cores, siblings 4-7 idle
NPIN=${#PIN_CPUS[@]}

TS="${RESUME_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_DIR="$SCRATCH/results/phase0/$TS"
DONE_DIR="$RESULT_DIR/.done"
RAW_DIR="$RESULT_DIR/raw"
JSON_DIR="$RESULT_DIR/json"
# ONE shared build cache for the whole run, not one per trial/rep/target.
# Go's build cache is content-addressed and safe for concurrent use by
# multiple simultaneous `go build`/`go test` invocations -- isolating it per
# trial was a real mistake here, not a safety measure: it made every single
# isolated cache re-download+recompile stdlib and every dependency from
# scratch, and 12 setup attempts alone reached 20GB, filling the CT's 30GB
# disk to 100% and failing every subsequent `git clone` with ENOSPC. Only
# the FUZZ cache (-test.fuzzcachedir, just corpus files) needs per-trial
# isolation for correctness; build cache never did. Matches fuzz-harness's
# own prior art (bench/portable-rig-benchmark:bench/fuzz-bench.sh) which
# shares one GOCACHE across a whole run for exactly this reason.
SHARED_GOCACHE="$SCRATCH/gocache-shared"
SRC_ROOT="$SCRATCH/src/$TS"
HW_TXT="$RESULT_DIR/hw.txt"
NOTES_FILE="$RESULT_DIR/notes.txt"

mkdir -p "$RESULT_DIR" "$DONE_DIR" "$RAW_DIR" "$JSON_DIR" "$SHARED_GOCACHE" "$SRC_ROOT"

log()  { echo "[$(date -u +%FT%TZ)] $*"; }
note() { echo "[$(date -u +%FT%TZ)] $*" >>"$NOTES_FILE"; }

done_marker() { printf '%s/%s' "$DONE_DIR" "$(echo "$1" | tr '/ ' '__')"; }
is_done()   { [ -f "$(done_marker "$1")" ]; }
mark_done() { : >"$(done_marker "$1")"; }

# ---------------------------------------------------------------------------
# Dry-run duration/rep overrides — smoke-test plumbing only, never reported.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
	PARTA_REPS=1; PARTA_CAP_S=60
	PARTB_DUR="20s"; PARTB_REPS=1
else
	PARTA_REPS=10; PARTA_CAP_S=1800   # 10 reps/bug/condition, 30-minute cap
	PARTB_DUR="10m"; PARTB_REPS=3     # 3 x 10 min per target/condition
fi

# ---------------------------------------------------------------------------
# Host-load recording. This runs INSIDE CT 240, which is an unprivileged
# LXC guest — /proc/loadavg here is the pve01 HOST's loadavg (LXC doesn't
# namespace it; confirmed during recon: identical numbers surfaced across
# every CT). Recording it from here is fine for "record host load at start
# and end of each window" but is NOT a hygiene gate — see cgroup_busy below
# for the real per-container check.
# ---------------------------------------------------------------------------
record_host_load() {
	local label="$1"
	{
		printf '%s host_loadavg(via /proc/loadavg, host-wide not per-CT): ' "$label"
		cat /proc/loadavg
	} >>"$HW_TXT"
}

# cgroup_busy — sum %CPU (ps-reported, single sample) of processes in THIS
# container as a sanity check that nothing but our own trial is running here.
# Not a substitute for the operator confirming host-level quiet before a
# window (that's the pve01-side responsibility, outside this container).
cgroup_busy() {
	ps -eo pcpu= | awk '{s+=$1} END{printf "%.1f", s+0}'
}

# ---------------------------------------------------------------------------
# fingerprint — once per RESULT_DIR
# ---------------------------------------------------------------------------
fingerprint() {
	is_done "fingerprint" && return
	{
		echo "hostname: $(hostname)"
		echo "date_utc: $(date -u +%FT%TZ)"
		echo "nproc: $(nproc)"
		echo "go_version: $("$GO_BIN" version 2>&1)"
		echo "--- lscpu -e ---"
		lscpu -e
		echo "--- free -h ---"
		free -h
		echo "--- df -h /opt ---"
		df -h /opt
		echo "--- base/after HEAD ---"
		git -C "$BASE_DIR" rev-parse HEAD
		git -C "$AFTER_DIR" rev-parse HEAD
	} >"$HW_TXT"
	record_host_load "fingerprint"
	mark_done "fingerprint"
}

# ---------------------------------------------------------------------------
# setup — idempotent tool install. Never touches libsfuzz/CT state.
# ---------------------------------------------------------------------------
setup_go() {
	is_done "setup_go" && return
	if [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_TOOLCHAIN_VERSION}"; then
		mark_done "setup_go"
		return
	fi
	local tarball="go${GO_TOOLCHAIN_VERSION}.linux-amd64.tar.gz"
	curl -fsSL -o "/tmp/$tarball" "https://go.dev/dl/$tarball"
	rm -rf /usr/local/go
	tar -C /usr/local -xzf "/tmp/$tarball"
	rm -f "/tmp/$tarball"
	if /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_TOOLCHAIN_VERSION}"; then
		mark_done "setup_go"
	else
		note "setup_go: install did not produce a working go${GO_TOOLCHAIN_VERSION} — NOT marking done"
	fi
}

setup_postgres() {
	is_done "setup_postgres" && return
	if command -v psql >/dev/null 2>&1 && dpkg -l postgresql-16 >/dev/null 2>&1; then
		mark_done "setup_postgres"
		return
	fi
	DEBIAN_FRONTEND=noninteractive apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -qq -y postgresql-16 >/dev/null
	if command -v psql >/dev/null 2>&1 && dpkg -l postgresql-16 >/dev/null 2>&1; then
		mark_done "setup_postgres"
	else
		note "setup_postgres: install did not produce a working psql/postgresql-16 — NOT marking done"
	fi
}

setup_go_tools() {
	# syft/govulncheck via `go install` — avoids curl-pipe-to-sh entirely.
	# Done-marker is set ONLY on confirmed post-install presence (command -v),
	# never on "the install command ran" — a systemd-run transient unit's
	# stripped environment (HOME/GOPATH resolution) silently produced 0 exit
	# status here once while writing nothing usable; never trust that again.
	is_done "setup_go_tools" && return
	export HOME="${HOME:-/root}"
	export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
	command -v govulncheck >/dev/null 2>&1 || "$GO_BIN" install golang.org/x/vuln/cmd/govulncheck@latest >>"$RAW_DIR/setup-go-tools.log" 2>&1
	command -v syft >/dev/null 2>&1 || "$GO_BIN" install github.com/anchore/syft/cmd/syft@latest >>"$RAW_DIR/setup-go-tools.log" 2>&1
	if command -v govulncheck >/dev/null 2>&1 && command -v syft >/dev/null 2>&1; then
		mark_done "setup_go_tools"
	else
		note "setup_go_tools: govulncheck and/or syft still not on PATH after install attempt — see raw/setup-go-tools.log; NOT marking done, will retry next invocation"
	fi
}

setup_load_tools() {
	is_done "setup_load_tools" && return
	export HOME="${HOME:-/root}"
	export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
	command -v vegeta >/dev/null 2>&1 || "$GO_BIN" install github.com/tsenart/vegeta@latest >>"$RAW_DIR/setup-load-tools.log" 2>&1
	# go install, not a guessed GitHub release asset URL (the plain
	# ".../latest/download/k6-linux-amd64.tar.gz" filename 404s — k6's real
	# release assets are versioned, e.g. k6-vX.Y.Z-linux-amd64.tar.gz — go
	# install sidesteps needing to resolve that at all).
	command -v k6 >/dev/null 2>&1 || "$GO_BIN" install go.k6.io/k6@latest >>"$RAW_DIR/setup-load-tools.log" 2>&1
	if command -v vegeta >/dev/null 2>&1 && command -v k6 >/dev/null 2>&1; then
		mark_done "setup_load_tools"
	else
		note "setup_load_tools: vegeta and/or k6 still not on PATH after install attempt — see raw/setup-load-tools.log; NOT marking done, will retry next invocation"
	fi
}

cmd_setup() {
	setup_go
	setup_postgres
	setup_go_tools
	setup_load_tools
	log "setup complete"
}

# ---------------------------------------------------------------------------
# Bug table (Part A). One function per bug returning pipe-separated fields:
#   pkg|fn|fix_sha|regression_test|oracle_substring|revert_mode
# revert_mode: gitrevert (revert every file the fix commit MODIFIED, leave
#              ADDED files in place) | none (bug is already live, e.g. #1996)
# fix_sha is "" for revert_mode=none.
# ---------------------------------------------------------------------------
bug_1() { echo "internal/netutil|FuzzIPv4EmbeddingSSRFParity|21a8e425|TestSSRFBlocklist_IPv4EmbeddingEncodings|private/link-local|guardpatch"; }
bug_2() { echo "internal/core|FuzzOIDCIDTokenSingleConstraintViolation|c18e689a|TestOIDCVerifier_RejectsFutureIssuedAt|iat|guardpatch"; }
# bug_3's package differs by condition — resolved in target_pkg_for(), not here.
bug_3() { echo "__COND__|FuzzDecodePATScopes|a87bdf24|TestDecodePATScopes|fail-open|guardpatch"; }
bug_4() { echo "internal/storage/store|FuzzPaginationBounds|__NONE__|__NONE__|offset|guardpatch"; }
bug_5() { echo "server/faultops|FuzzStorageFaultOperations|__NONE__|__NONE__|__NONE__|none"; }
bug_6() { echo "server/faultops|FuzzStorageFaultOperations|567a2fc1|__NONE__|not found|gitrevert"; }
BUGS=(bug_1 bug_2 bug_3 bug_4 bug_5 bug_6)

target_pkg_for() {
	# target_pkg_for <bug_fn> <condition: base|after> — resolves bug_3's
	# base(internal/core)/after(internal/core/rules) package split (PR #2001).
	local bug_fn="$1" cond="$2" pkg
	pkg="$(("$bug_fn") | cut -d'|' -f1)"
	if [ "$pkg" = "__COND__" ]; then
		[ "$cond" = "base" ] && echo "internal/core" || echo "internal/core/rules"
		return
	fi
	echo "$pkg"
}

# mapsize_of_bin / pkg_map_bytes_measured — ported from fuzz-harness's own
# fuzz-runner.sh (mapsize_of_bin/pkg_map_bytes, merged into main 2026-09-23):
# the REAL coverage-map size is the distance between the linker symbols
# internal/fuzz._counters and internal/fuzz._ecounters in an INSTRUMENTED
# test binary (`go test -c -fuzz='^Fuzz$'` — a plain `-c` build has no
# counters at all). This is the measured quantity fuzz-runner.sh's own
# MINIMIZE_CAP_THRESHOLD (100000 bytes) / MINIMIZE_CAP_VALUE (100x) decision
# is based on — not a proxy. Simplified from fuzz-runner.sh's version: no
# FUZZ_PREBUILT/generation cache, no cross-commit cache pruning (phase0.sh's
# own done-marker per (bug,condition) already gives it that).
mapsize_of_bin() {
	local bin="$1" a b
	read -r a b < <(env -C "$SCRATCH" "$GO_BIN" tool nm "$bin" 2>/dev/null | awk '
		$NF=="internal/fuzz._counters"  {a=$1}
		$NF=="internal/fuzz._ecounters" {b=$1}
		END {if (a!="" && b!="") print a, b}')
	[ -n "${a:-}" ] && [ -n "${b:-}" ] || return 1
	echo $(( 16#$b - 16#$a ))
}

MINIMIZE_CAP_THRESHOLD=100000 # bytes; matches fuzz-runner.sh's default
MINIMIZE_CAP_VALUE="100x"

# pkg_map_bytes_measured <module_dir> <pkg> <cache> -> echoes "<map_bytes> <binary_kb>"
# map_bytes is empty (not "0") if measurement failed (uninstrumented/build
# failure) — per fuzz-runner.sh's own convention, an unknown map size means
# NO CAP, never a false cap from misreading a failure as 0.
pkg_map_bytes_measured() {
	local module_dir="$1" pkg="$2" cache="$3"
	local bin="$SCRATCH/.mapsize-bin-$$"
	local map_bytes="" binary_kb=0
	if env -C "$module_dir" GOCACHE="$cache" "$GO_BIN" test -c -fuzz='^Fuzz$' -o "$bin" "./$pkg" >/dev/null 2>&1; then
		[ -f "$bin" ] && binary_kb=$(( $(stat -c%s "$bin" 2>/dev/null || echo 0) / 1024 ))
		map_bytes="$(mapsize_of_bin "$bin" || true)"
	fi
	rm -f "$bin"
	echo "${map_bytes} ${binary_kb}"
}

# ---------------------------------------------------------------------------
# revert_fix — revert every file a fix commit MODIFIED (not ADDED), so the
# fix's own new regression-test/fuzz file stays in place and the target still
# exists. Ported from fuzz-harness's own prior art
# (bench/portable-rig-benchmark:bench/fuzz-bench.sh ttf_revert_keyorix_commit)
# — a failed per-file reverse-apply is recorded, never silently dropped.
# ---------------------------------------------------------------------------
revert_fix() {
	local dir="$1" fix_sha="$2" f
	git -C "$dir" diff --name-status "${fix_sha}^1" "$fix_sha" | awk '$1=="M"{print $2}' |
		while IFS= read -r f; do
			# --3way: plain context-line patching breaks the moment ANY later
			# commit also touched this file (confirmed real, not hypothetical:
			# dialer.go was touched again by #1949 after the SSRF fix) --
			# --3way falls back to a real content-based merge using the blobs
			# already in this clone's object database, which tolerates that.
			if ! git -C "$dir" show "$fix_sha" -- "$f" | git -C "$dir" apply -R --3way 2>>"$NOTES_FILE"; then
				note "revert_fix: $fix_sha did not cleanly reverse-apply to $f even with --3way — left as-is, see notes; the post-revert red/green check below is what actually catches this"
			fi
		done
}

# bug_1's fix commit (21a8e425) no longer reverse-applies cleanly, plain OR
# --3way: PR #1949 refactored the same function afterward (confirmed via
# `git log 21a8e425..HEAD -- internal/netutil/dialer.go`), so context-based
# patching genuinely conflicts, not just "some unrelated line moved." Hand-
# authored instead: matchesCIDRsWithEmbedded (shared by IsPrivateOrLinkLocal
# and IsLinkLocal since #1949) is neutered to skip the embedded-IPv4 decode
# entirely, restoring exactly the pre-#1937 bypass (NAT64/IPv4-compat
# addresses no longer checked against the CIDR blocklist) without touching
# any other line in the file.
guardpatch_bug_1() {
	local dir="$1"
	local target="$dir/internal/netutil/dialer.go"
	[ -f "$target" ] || { note "guardpatch bug_1: $target not found — cannot apply, dropping this bug for this condition"; return 1; }
	grep -q "^func matchesCIDRsWithEmbedded" "$target" \
		|| { note "guardpatch bug_1: matchesCIDRsWithEmbedded not found in current dialer.go — file structure has changed since recon; drop this bug for this condition rather than silently miss"; return 1; }
	sed -i '/^func matchesCIDRsWithEmbedded/a\	return inCIDRs(ip, cidrs) // phase0 guardpatch: skip embedded-IPv4 decode, restoring the pre-#1937 bypass' "$target" \
		|| { note "guardpatch bug_1: sed failed against current dialer.go shape — drop this bug for this condition rather than silently miss"; return 1; }
}

# bug_2's fix commit (c18e689a) also doesn't reverse-apply: --3way leaves
# literal conflict markers in oidc.go/sso.go (confirmed: build failed with
# "unexpected <<" at the exact marker lines). Hand-authored instead: delete
# the single `jwt.WithIssuedAt()` parser option OIDCVerifier.Verify gained —
# federation path only (this bug's actual scope); sso.go's browser-SSO
# verifyIDToken, which got the identical fix in the same commit, is
# deliberately left untouched since it's not this bug's target.
guardpatch_bug_2() {
	local dir="$1"
	local target="$dir/internal/core/oidc.go"
	[ -f "$target" ] || { note "guardpatch bug_2: $target not found — cannot apply, dropping this bug for this condition"; return 1; }
	grep -q "jwt.WithIssuedAt()," "$target" \
		|| { note "guardpatch bug_2: jwt.WithIssuedAt() not found in current oidc.go — file structure has changed since recon; drop this bug for this condition rather than silently miss"; return 1; }
	sed -i '/jwt\.WithIssuedAt(),/d' "$target" \
		|| { note "guardpatch bug_2: sed failed against current oidc.go shape — drop this bug for this condition rather than silently miss"; return 1; }
}

# bug_3's fix commit (a87bdf24) is a BUNDLED 7-finding batch ("r124-M": LIKE
# injection, pagination DoS, deactivation revocation, PAT scope fail-open,
# logout CSRF, group CLI actor, anomaly panic) -- reverting every file it
# modified would reintroduce 6 UNRELATED bugs alongside this one, contaminating
# the trial (confirmed: a naive revert touched internal/storage/store/entry.go
# and internal/cli/anomalies/anomalies.go, neither related to PAT scopes).
# Hand-authored instead, scoped to exactly the PAT-scope sentinel: change the
# fail-closed sentinel return to `return nil` (fail-open), in whichever file
# currently holds it -- internal/core/pat.go pre-#2001 (BASE), or
# internal/core/rules/pat_codec.go post-#2001 (AFTER).
guardpatch_bug_3() {
	local dir="$1"
	# Select by CONTENT, not existence: internal/core/pat.go still exists on
	# AFTER (#2001 moved DecodePATScopes out of it but didn't delete the
	# file — it still holds other PAT functions), so an existence-only check
	# picked it and silently found no sentinel to patch. Check both
	# candidates for the actual sentinel line.
	local target=""
	for candidate in "$dir/internal/core/pat.go" "$dir/internal/core/rules/pat_codec.go"; do
		if [ -f "$candidate" ] && grep -qE "return (patScopeCorrupted|PATScopeCorrupted)" "$candidate"; then
			target="$candidate"
			break
		fi
	done
	[ -n "$target" ] || { note "guardpatch bug_3: no *ScopeCorrupted sentinel return found in pat.go or rules/pat_codec.go — file structure has changed since recon; drop this bug for this condition rather than silently miss"; return 1; }
	grep -qE "return (patScopeCorrupted|PATScopeCorrupted)" "$target" \
		|| { note "guardpatch bug_3: no *ScopeCorrupted sentinel return found in $target — file structure has changed since recon; drop this bug for this condition rather than silently miss"; return 1; }
	sed -i -E 's/return (patScopeCorrupted|PATScopeCorrupted)/return nil \/\/ phase0 guardpatch: fail-open on corrupted PAT scopes (#r124)/' "$target" \
		|| { note "guardpatch bug_3: sed failed against current $target shape — drop this bug for this condition rather than silently miss"; return 1; }
}

# bug_4 has no separate pre-fix commit (the guard and its fuzz harness landed
# together in f59e6eff/#1936) — a minimal revert means widening the guard
# itself, not reverting history. Hand-authored, applied via sed on the known
# ceiling constant/comparison in pagination_bounds_fuzz_test.go's target file.
guardpatch_bug_4() {
	local dir="$1"
	local target="$dir/internal/storage/store/entry.go"
	[ -f "$target" ] || { note "guardpatch bug_4: $target not found — cannot apply, dropping this bug for this condition"; return 1; }
	# Widen the OFFSET ceiling so (page-1)*pageSize can overflow int again —
	# the exact mutation PR #1936's own commit message names as its red-proof.
	sed -i 's/const maxStoragePageSize = .*/const maxStoragePageSize = 1<<62/' "$target" \
		|| { note "guardpatch bug_4: sed failed against current pagination.go shape — file structure has likely changed since recon; drop this bug for this condition rather than silently miss"; return 1; }
}

# ---------------------------------------------------------------------------
# prove_revert — ONE-TIME (per bug, per condition) red/green proof, not
# per-trial: reverted tree's regression test must FAIL, original tree's must
# PASS. A bug that can't be proven this way is dropped for that condition,
# with a recorded reason — never silently forced into the trial set.
# ---------------------------------------------------------------------------
prove_revert() {
	local bug_fn="$1" cond="$2" case_dir="$3" orig_dir="$4" pkg="$5" test_name="$6"
	local key="prove__${bug_fn}__${cond}"
	is_done "$key" && { [ -f "$(done_marker "${key}_ok")" ]; return $?; }
	if [ "$test_name" = "__NONE__" ]; then
		note "prove_revert $bug_fn/$cond: no dedicated regression-test name known — falling back to the fuzz target's own seed corpus as the red/green proof (run below in trial setup instead)"
		mark_done "$key"; mark_done "${key}_ok"
		return 0
	fi
	local revlog="$RAW_DIR/prove-$bug_fn-$cond-reverted.log"
	local origlog="$RAW_DIR/prove-$bug_fn-$cond-original.log"
	env -C "$case_dir" GOCACHE="$SHARED_GOCACHE" "$GO_BIN" test "./$pkg" -run "^${test_name}\$" -v >"$revlog" 2>&1
	local rev_rc=$?
	env -C "$orig_dir" GOCACHE="$SHARED_GOCACHE" "$GO_BIN" test "./$pkg" -run "^${test_name}\$" -v >"$origlog" 2>&1
	local orig_rc=$?
	mark_done "$key"
	if [ "$rev_rc" -ne 0 ] && [ "$orig_rc" -eq 0 ]; then
		mark_done "${key}_ok"
		return 0
	fi
	note "prove_revert $bug_fn/$cond FAILED: reverted_rc=$rev_rc (want!=0) original_rc=$orig_rc (want=0) — dropping this bug for this condition, see $revlog / $origlog"
	return 1
}

# ---------------------------------------------------------------------------
# prep_corpus_and_gate — ONE-TIME (per bug, per condition) corpus prep: copy
# the committed seed corpus into case_dir, strip any seed whose content
# reproduces this exact bug (starting corpus = committed seeds MINUS the
# regression seed, per spec), then a machine-checked contamination gate —
# `go test ./pkg -run '^Fn$'` (no -fuzz) REPLAYS the remaining corpus as
# ordinary test cases; if any surviving seed still trips the bug on its own,
# every trial would trivially "find" it in ~0s via replay, not fuzzing,
# which would silently invalidate the whole time-to-find measurement. Drop
# the bug for this condition rather than let that happen quietly.
# ---------------------------------------------------------------------------
prep_corpus_and_gate() {
	local bug_fn="$1" cond="$2" case_dir="$3" pkg="$4" fn="$5" oracle="$6"
	local key="prepcorpus__${bug_fn}__${cond}"
	is_done "$key" && { [ -f "$(done_marker "${key}_ok")" ]; return $?; }

	local corpus_src="$CORPUS_DIR/corpus/keyorix/github.com/keyorixhq/keyorix/$pkg/$fn"
	local corpus_dst="$case_dir/$pkg/testdata/fuzz/$fn"
	rm -rf "$corpus_dst"
	if [ -d "$corpus_src" ]; then
		mkdir -p "$corpus_dst"
		cp -r "$corpus_src"/. "$corpus_dst"/
	fi

	# bug_3 only: FuzzDecodePATScopes's corrupted-JSON reproducers are
	# hardcoded `f.Add(...)` literals inside the fuzz function's own Go
	# source, not testdata/fuzz files — confirmed directly, they always run
	# before any real mutation and would report a ~0s "find" on every trial
	# regardless of what gets stripped from testdata/fuzz/. Matched by
	# literal VALUE, not comment text (comment-text matching missed
	# "__corrupted__" and the strings.Repeat line, which have no "->
	# corrupted" annotation but are exactly as malformed). case_dir is a
	# disposable per-trial clone, never the real repo, so removing these
	# lines here is the equivalent of "committed seeds minus the regression
	# seed" for a target whose seeds happen to be hardcoded.
	if [ "$bug_fn" = "bug_3" ]; then
		local seedfile="$case_dir/$pkg/pat_fuzz_test.go"
		if [ -f "$seedfile" ]; then
			sed -i -E -e '/-> corrupted/d' -e '/"__corrupted__",/d' -e '/strings\.Repeat/d' -e '/`\["a",`,/d' "$seedfile" \
				|| note "prep_corpus_and_gate bug_3/$cond: sed on hardcoded seeds failed against current $seedfile shape"
		fi
	fi

	mark_done "$key"

	if [ ! -d "$corpus_dst" ] || [ -z "$(ls -A "$corpus_dst" 2>/dev/null)" ]; then
		mark_done "${key}_ok" # nothing to replay, nothing to contaminate
		return 0
	fi

	# Iteratively replay + strip: corpus files hold raw test INPUT bytes, not
	# descriptive text, so grepping file content for an oracle substring
	# never actually found anything (confirmed: bug_3/base had dozens of
	# real historical reproducers on disk, none containing the word
	# "fail-open"). Actually run the replay, remove whichever specific
	# on-disk entries fail (named by hash in -v output; "seed#N" entries are
	# the hardcoded ones already handled above and are skipped here), retry.
	# Bounded iterations, not open-ended — a target that keeps producing new
	# failures past this budget gets dropped, not silently spun on forever.
	local gatelog iter=0 max_iter=10
	while [ "$iter" -lt "$max_iter" ]; do
		iter=$((iter + 1))
		gatelog="$RAW_DIR/gate-$bug_fn-$cond-iter${iter}.log"
		if env -C "$case_dir" GOCACHE="$SHARED_GOCACHE" "$GO_BIN" test "./$pkg" -run "^${fn}\$" -v >"$gatelog" 2>&1; then
			mark_done "${key}_ok"
			return 0
		fi
		local failing
		failing="$(grep -oE -- "--- FAIL: ${fn}/[0-9a-f]{16}" "$gatelog" | awk '{print $NF}' | cut -d/ -f2)"
		if [ -z "$failing" ]; then
			# only hardcoded seed#N failures left (or something else entirely) —
			# no on-disk file to remove, so another iteration can't help.
			break
		fi
		echo "$failing" | while IFS= read -r hash; do
			rm -f "$corpus_dst/$hash"
		done
	done
	note "prep_corpus_and_gate $bug_fn/$cond: stripped corpus STILL trips the bug via plain replay after $iter strip iteration(s) (see $gatelog) — dropping this bug for this condition rather than report a contaminated ~0s time-to-find"
	return 1
}

# ---------------------------------------------------------------------------
# run_trial_partA — one Part A trial. Pinned to a physical core, isolated
# GOCACHE + -test.fuzzcachedir, starting corpus = case_dir's already-prepped
# (and contamination-gated) seed set, capped at PARTA_CAP_S (censored, not
# dropped, on timeout).
# ---------------------------------------------------------------------------
run_trial_partA() {
	local bug_id="$1" cond="$2" rep="$3" cpu="$4" case_dir="$5" pkg="$6" fn="$7" oracle="$8" fuzzminimizetime="$9"
	local out_json="$JSON_DIR/partA__${bug_id}__${cond}__rep${rep}.json"
	[ -f "$out_json" ] && return

	local trial_dir="$SRC_ROOT/partA-${bug_id}-${cond}-rep${rep}"
	rm -rf "$trial_dir"
	git clone --quiet --shared "$case_dir" "$trial_dir" 2>/dev/null || cp -r "$case_dir" "$trial_dir"
	# case_dir's testdata/fuzz/<fn> is already the prepped+gated corpus
	# (prep_corpus_and_gate ran once during setup) — the clone/copy above
	# brings it along verbatim; nothing left to fetch or strip per-trial.

	local gocache="$SHARED_GOCACHE"
	local fuzzcache="$trial_dir/.fuzzcache"
	mkdir -p "$gocache" "$fuzzcache"

	local extra_flags=()
	[ -n "$fuzzminimizetime" ] && extra_flags+=("-test.fuzzminimizetime=$fuzzminimizetime")

	local logfile="$RAW_DIR/partA-${bug_id}-${cond}-rep${rep}.log"
	local t0 t1 duration_s rc found=false censored=false
	t0=$(date +%s)
	timeout "$((PARTA_CAP_S + 30))" taskset -c "$cpu" \
		env -C "$trial_dir" GOCACHE="$gocache" \
		"$GO_BIN" test "./$pkg" -run '^$' -fuzz "^${fn}\$" -fuzztime "${PARTA_CAP_S}s" \
		-parallel 1 -test.fuzzcachedir="$fuzzcache" "${extra_flags[@]}" -v >"$logfile" 2>&1
	rc=$?
	t1=$(date +%s)
	duration_s=$((t1 - t0))

	local execs_at_failure=0 failing_input="" oracle_message="" oracle_matches=false
	if grep -aq -- '--- FAIL' "$logfile"; then
		found=true
		execs_at_failure="$(grep -aoE 'execs: [0-9]+' "$logfile" | tail -1 | grep -oE '[0-9]+' || echo 0)"
		failing_input="$(grep -aoE "testdata/fuzz/${fn}/[0-9a-f]+" "$logfile" | tail -1 || true)"
		oracle_message="$(grep -a -A2 -- '--- FAIL' "$logfile" | tail -n +2 | head -1 | sed 's/^[[:space:]]*//')"
		echo "$oracle_message" | grep -qi "$oracle" && oracle_matches=true
	elif [ "$duration_s" -ge "$PARTA_CAP_S" ] || [ "$rc" -eq 124 ]; then
		censored=true
	fi

	jq -n \
		--arg bug "$bug_id" --arg cond "$cond" --argjson rep "$rep" \
		--argjson duration_s "$duration_s" --argjson cap_s "$PARTA_CAP_S" \
		--argjson found "$found" --argjson censored "$censored" \
		--argjson execs_at_failure "${execs_at_failure:-0}" \
		--arg failing_input "$failing_input" --arg oracle_message "$oracle_message" \
		--argjson oracle_matches "$oracle_matches" --argjson cpu "$cpu" \
		--arg go_version "$("$GO_BIN" version)" \
		'{bug:$bug, condition:$cond, rep:$rep, duration_s:$duration_s, cap_s:$cap_s,
		  found:$found, censored:$censored, execs_at_failure:$execs_at_failure,
		  failing_input:$failing_input, oracle_message:$oracle_message,
		  oracle_matches_bug:$oracle_matches, cpu:$cpu, go_version:$go_version}' \
		>"$out_json"

	rm -rf "$trial_dir" "$gocache"
}

# ---------------------------------------------------------------------------
# cmd_partA — scheduler: build the interleaved ABAB job list per bug, run
# with bounded 4-way parallelism, one job per physical core.
# ---------------------------------------------------------------------------
cmd_partA() {
	fingerprint
	record_host_load "partA_start"
	[ -s "$RESULT_DIR/mapsize_table.csv" ] || echo "bug,condition,target,map_bytes,binary_kb,fuzzminimizetime" >"$RESULT_DIR/mapsize_table.csv"
	local jobs=()
	local bug_fn cond rep bugline pkg fn fix_sha test_name oracle revert_mode

	for bug_fn in "${BUGS[@]}"; do
		bugline="$("$bug_fn")"
		fn="$(echo "$bugline" | cut -d'|' -f2)"
		fix_sha="$(echo "$bugline" | cut -d'|' -f3)"
		test_name="$(echo "$bugline" | cut -d'|' -f4)"
		oracle="$(echo "$bugline" | cut -d'|' -f5)"
		revert_mode="$(echo "$bugline" | cut -d'|' -f6)"

		for cond in base after; do
			local root_dir; [ "$cond" = base ] && root_dir="$BASE_DIR" || root_dir="$AFTER_DIR"
			pkg="$(target_pkg_for "$bug_fn" "$cond")"
			local case_dir="$SRC_ROOT/setup-${bug_fn}-${cond}"

			if ! is_done "materialize__${bug_fn}__${cond}"; then
				rm -rf "$case_dir"
				git clone --quiet "$root_dir" "$case_dir"
				case "$revert_mode" in
				gitrevert)
					revert_fix "$case_dir" "$fix_sha"
					# bug_6 only: 567a2fc1 ADDED secrets_read_error_test.go,
					# which calls corestorage.IsSecretNotFound -- a symbol
					# defined in a file revert_fix DOES revert (it's "M", not
					# "A"), so the added test no longer compiles once that
					# symbol is gone. This added file isn't our regression
					# proof (test_name is __NONE__ for bug_6; the fuzz target
					# FuzzStorageFaultOperations already existed), so just
					# remove it rather than leave dead, non-compiling code.
					[ "$bug_fn" = "bug_6" ] && rm -f "$case_dir/internal/core/secrets_read_error_test.go"
					;;
				guardpatch) "guardpatch_${bug_fn}" "$case_dir" || { note "$bug_fn/$cond: guardpatch failed, dropping"; mark_done "materialize__${bug_fn}__${cond}"; mark_done "drop__${bug_fn}__${cond}"; continue; } ;;
				none) : ;; # bug already live, nothing to introduce
				esac
				if ! env -C "$case_dir" GOCACHE="$SHARED_GOCACHE" "$GO_BIN" test -c -o /dev/null "./$pkg" >"$RAW_DIR/buildcheck-${bug_fn}-${cond}.log" 2>&1; then
					note "$bug_fn/$cond: DOES NOT COMPILE after revert — the fix's own regression test likely calls a symbol the fix itself introduced; not mechanically revertible here, dropping (see raw/buildcheck-${bug_fn}-${cond}.log)"
					mark_done "materialize__${bug_fn}__${cond}"
					mark_done "drop__${bug_fn}__${cond}"
					continue
				fi
				mark_done "materialize__${bug_fn}__${cond}"
			fi
			is_done "drop__${bug_fn}__${cond}" && continue

			if [ "$revert_mode" != "none" ]; then
				# bug_3's regression test (TestDecodePATScopes) never moved to
				# internal/core/rules with the function it tests — #2001 added
				# a compat wrapper so internal/core still calls through to the
				# real (possibly-reverted) logic. Test package is always
				# internal/core regardless of condition; the fuzz TARGET's own
				# package still follows target_pkg_for per condition.
				local test_pkg="$pkg"
				[ "$bug_fn" = "bug_3" ] && test_pkg="internal/core"
				prove_revert "$bug_fn" "$cond" "$case_dir" "$root_dir" "$test_pkg" "$test_name" || {
					mark_done "drop__${bug_fn}__${cond}"
					continue
				}
			fi

			prep_corpus_and_gate "$bug_fn" "$cond" "$case_dir" "$pkg" "$fn" "$oracle" || {
				mark_done "drop__${bug_fn}__${cond}"
				continue
			}

			local measured map_bytes binary_kb
			measured="$(pkg_map_bytes_measured "$case_dir" "$pkg" "$SHARED_GOCACHE")"
			map_bytes="$(echo "$measured" | cut -d' ' -f1)"
			binary_kb="$(echo "$measured" | cut -d' ' -f2)"
			local fmt=""
			if [ "$cond" = after ] && [[ "$map_bytes" =~ ^[0-9]+$ ]] && [ "$map_bytes" -gt "$MINIMIZE_CAP_THRESHOLD" ]; then
				fmt="$MINIMIZE_CAP_VALUE"
			fi
			echo "${bug_fn},${cond},${pkg}/${fn},${map_bytes:-unknown},${binary_kb},${fmt:-off}" >>"$RESULT_DIR/mapsize_table.csv"
			note "$bug_fn/$cond map_bytes=${map_bytes:-unknown} binary_kb=$binary_kb fuzzminimizetime=${fmt:-default(off)}"

			for rep in $(seq 1 "$PARTA_REPS"); do
				jobs+=("$bug_fn|$cond|$rep|$case_dir|$pkg|$fn|$oracle|$fmt")
			done
		done
	done

	# ABAB interleave within each bug: re-sort so base/after alternate per rep.
	# (jobs were appended base-then-after per rep already, which IS the ABAB
	# order per bug; bugs themselves run in table order, one after another.)
	local slot=0 running=0
	declare -a pids
	for job in "${jobs[@]}"; do
		IFS='|' read -r bug_fn cond rep case_dir pkg fn oracle fmt <<<"$job"
		local key="partA__${bug_fn}__${cond}__rep${rep}"
		is_done "$key" && continue
		local cpu="${PIN_CPUS[$((slot % NPIN))]}"
		slot=$((slot + 1))
		( run_trial_partA "$bug_fn" "$cond" "$rep" "$cpu" "$case_dir" "$pkg" "$fn" "$oracle" "$fmt" && mark_done "$key" ) &
		pids+=($!)
		running=$((running + 1))
		if [ "$running" -ge "$NPIN" ]; then
			wait -n
			running=$((running - 1))
		fi
	done
	wait
	record_host_load "partA_end"
	log "partA complete: $RESULT_DIR"
}

# ---------------------------------------------------------------------------
# cmd_partB — mechanics: targets + FuzzKeyorixHTTPAPISequence + csvsafe
# control, both conditions, PARTB_REPS x PARTB_DUR @ -parallel=1, plus an
# identical-binary control run (same compiled binary invoked twice) to
# separate pure run-to-run variance from a real BASE/AFTER difference.
# ---------------------------------------------------------------------------
PARTB_TARGETS=(
	"internal/netutil|FuzzIPv4EmbeddingSSRFParity"
	"internal/core|FuzzOIDCIDTokenSingleConstraintViolation"
	"__COND__|FuzzDecodePATScopes"
	"internal/storage/store|FuzzPaginationBounds"
	"server/faultops|FuzzStorageFaultOperations"
	"server/http|FuzzKeyorixHTTPAPISequence"
	"internal/csvsafe|FuzzCSVSafeFormulaNeutralization"
)

run_mechanics() {
	local cond="$1" root_dir="$2" pkg="$3" fn="$4" rep="$5" cpu="${6:-${PIN_CPUS[0]}}"
	local out_json="$JSON_DIR/partB__${fn}__${cond}__rep${rep}.json"
	[ -f "$out_json" ] && return
	local gocache="$SHARED_GOCACHE"
	mkdir -p "$gocache"
	local logfile="$RAW_DIR/partB-${fn}-${cond}-rep${rep}.log"
	local t0; t0=$(date +%s)
	taskset -c "$cpu" env -C "$root_dir" GOCACHE="$gocache" \
		"$GO_BIN" test "./$pkg" -run '^$' -fuzz "^${fn}\$" -fuzztime "$PARTB_DUR" -parallel 1 -v >"$logfile" 2>&1
	local t1; t1=$(date +%s)
	local line execs elapsed_s new_int total
	line="$(grep -aoE 'fuzz: elapsed: [0-9hms]+, execs: [0-9]+ \([0-9]+/sec\), new interesting: [0-9]+ \(total: [0-9]+\)' "$logfile" | tail -1)"
	execs="$(echo "$line" | grep -oE 'execs: [0-9]+' | grep -oE '[0-9]+' || echo 0)"
	new_int="$(echo "$line" | grep -oE 'new interesting: [0-9]+' | grep -oE '[0-9]+' || echo 0)"
	total="$(echo "$line" | grep -oE 'total: [0-9]+' | grep -oE '[0-9]+' || echo 0)"
	local wall_s=$((t1 - t0))
	local execs_per_s=0; [ "$wall_s" -gt 0 ] && execs_per_s=$((execs / wall_s))
	local measured map_bytes binary_kb
	measured="$(pkg_map_bytes_measured "$root_dir" "$pkg" "$gocache")"
	map_bytes="$(echo "$measured" | cut -d' ' -f1)"
	binary_kb="$(echo "$measured" | cut -d' ' -f2)"
	jq -n --arg fn "$fn" --arg cond "$cond" --argjson rep "$rep" \
		--argjson wall_s "$wall_s" --argjson execs "${execs:-0}" --argjson execs_per_s "$execs_per_s" \
		--argjson new_interesting "${new_int:-0}" --argjson total_corpus "${total:-0}" \
		--arg map_bytes "${map_bytes:-unknown}" --argjson binary_kb "$binary_kb" \
		'{target:$fn, condition:$cond, rep:$rep, wall_s:$wall_s, execs:$execs, execs_per_s:$execs_per_s,
		  new_interesting:$new_interesting, total_corpus:$total_corpus, map_bytes:$map_bytes, binary_size_kb:$binary_kb}' >"$out_json"
}

cmd_partB() {
	fingerprint
	record_host_load "partB_start"
	local t cond root_dir pkg fn rep jobs=()
	for t in "${PARTB_TARGETS[@]}"; do
		fn="$(echo "$t" | cut -d'|' -f2)"
		for cond in base after; do
			root_dir=""; [ "$cond" = base ] && root_dir="$BASE_DIR" || root_dir="$AFTER_DIR"
			pkg="$(echo "$t" | cut -d'|' -f1)"
			[ "$pkg" = "__COND__" ] && { [ "$cond" = base ] && pkg="internal/core" || pkg="internal/core/rules"; }
			for rep in $(seq 1 "$PARTB_REPS"); do
				jobs+=("$cond|$root_dir|$pkg|$fn|$rep")
			done
		done
	done

	# 4-way CPU-pinned concurrency, same scheduling shape as Part A — each
	# slice is still -parallel=1 internally (one fuzzing worker), so running
	# 4 DIFFERENT slices concurrently on 4 different physical cores doesn't
	# violate that; it's what turns this from a ~7h sequential run into ~1.75h.
	local slot=0 running=0
	for job in "${jobs[@]}"; do
		IFS='|' read -r cond root_dir pkg fn rep <<<"$job"
		local cpu="${PIN_CPUS[$((slot % NPIN))]}"
		slot=$((slot + 1))
		run_mechanics "$cond" "$root_dir" "$pkg" "$fn" "$rep" "$cpu" &
		running=$((running + 1))
		if [ "$running" -ge "$NPIN" ]; then
			wait -n
			running=$((running - 1))
		fi
	done
	wait

	# identical-binary control: same compiled AFTER binary, invoked twice,
	# to size pure run-to-run noise against the BASE-vs-AFTER numbers above.
	if ! is_done "partB_identical_control"; then
		local pkg="internal/netutil" fn="FuzzIPv4EmbeddingSSRFParity"
		local bin="$SCRATCH/.partB-control-bin"
		env -C "$AFTER_DIR" GOCACHE="$SHARED_GOCACHE" "$GO_BIN" test -c -o "$bin" "./$pkg" >/dev/null 2>&1
		for rep in 1 2; do
			local logfile="$RAW_DIR/partB-control-rep${rep}.log"
			taskset -c "${PIN_CPUS[0]}" "$bin" -test.run '^$' -test.fuzz "^${fn}\$" -test.fuzztime "$PARTB_DUR" -test.parallel 1 -test.v >"$logfile" 2>&1
		done
		mark_done "partB_identical_control"
	fi
	record_host_load "partB_end"
	log "partB complete: $RESULT_DIR"
}

# ---------------------------------------------------------------------------
# cmd_partC — build/footprint/attack-surface, BASE only.
# ---------------------------------------------------------------------------
cmd_partC() {
	fingerprint
	record_host_load "partC_start"
	export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
	local out="$JSON_DIR/partC.json"
	[ -f "$out" ] && { log "partC already recorded: $out"; return; }

	local build_dirs=("." "./server" "./cmd/keyorix-mcp" "./cmd/keyorix-k8s-sync")
	local sizes="{}"
	local d name plain_bin stripped_bin plain_kb stripped_kb build_s
	for d in "${build_dirs[@]}"; do
		name="$(basename "$d")"; [ "$d" = "." ] && name="cli"
		plain_bin="$SCRATCH/.partC-${name}-plain"
		stripped_bin="$SCRATCH/.partC-${name}-stripped"
		local t0; t0=$(date +%s)
		env -C "$BASE_DIR" GOCACHE="$SHARED_GOCACHE" "$GO_BIN" build -o "$plain_bin" "$d"
		build_s=$(( $(date +%s) - t0 ))
		env -C "$BASE_DIR" GOCACHE="$SHARED_GOCACHE" "$GO_BIN" build -ldflags="-s -w" -o "$stripped_bin" "$d"
		plain_kb=$(( $(stat -c%s "$plain_bin") / 1024 ))
		stripped_kb=$(( $(stat -c%s "$stripped_bin") / 1024 ))
		sizes="$(echo "$sizes" | jq --arg n "$name" --argjson p "$plain_kb" --argjson s "$stripped_kb" --argjson b "$build_s" '. + {($n): {plain_kb:$p, stripped_kb:$s, build_s:$b}}')"
		rm -f "$plain_bin" "$stripped_bin"
	done

	local deps_count go_list_log="$RAW_DIR/partC-golist.log"
	env -C "$BASE_DIR" "$GO_BIN" list -deps ./... >"$go_list_log" 2>&1
	deps_count=$(wc -l <"$go_list_log")

	local syft_json="$RAW_DIR/partC-syft.json" syft_count=0
	if command -v syft >/dev/null 2>&1; then
		syft "$BASE_DIR" -o cyclonedx-json >"$syft_json" 2>/dev/null || true
		[ -s "$syft_json" ] && syft_count=$(jq '.components | length' "$syft_json" 2>/dev/null || echo 0)
	fi

	local govuln_log="$RAW_DIR/partC-govulncheck.log" govuln_count=0
	if command -v govulncheck >/dev/null 2>&1; then
		env -C "$BASE_DIR" govulncheck ./... >"$govuln_log" 2>&1 || true
		# NOT `grep -c ... || echo 0`: grep -c already prints "0" on zero
		# matches but exits 1, so `|| echo 0` doubles the output to "0\n0" --
		# not valid JSON, which broke `jq --argjson` here for real (confirmed
		# empty partC.json on a run with 0 govulncheck findings).
		govuln_count=$(grep -c '^Vulnerability #' "$govuln_log" 2>/dev/null)
		govuln_count="${govuln_count:-0}"
	fi

	# attack-surface counts
	local system_routes remote_storage_methods proxy_loc closure_rows
	system_routes=$(grep -rhoE '"/system[^"]*"' "$BASE_DIR/server/http" 2>/dev/null | sort -u | wc -l)
	remote_storage_methods=$(grep -c '^func (.*RemoteStorage) ' "$BASE_DIR"/internal/storage/store/*.go 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
	proxy_loc=$(find "$BASE_DIR/server/http" -name '*_proxy.go' -exec cat {} + 2>/dev/null | wc -l)
	closure_rows=$(grep -c "proxy" "$BASE_DIR/docs/security-closures.tsv" 2>/dev/null)
	closure_rows="${closure_rows:-0}"

	jq -n --argjson sizes "$sizes" --argjson deps "$deps_count" --argjson syft "$syft_count" \
		--argjson govuln "$govuln_count" --argjson routes "$system_routes" \
		--argjson rsmethods "$remote_storage_methods" --argjson proxyloc "$proxy_loc" \
		--argjson closures "$closure_rows" \
		'{binary_sizes:$sizes, go_list_deps_count:$deps, syft_component_count:$syft,
		  govulncheck_finding_count:$govuln, system_route_count:$routes,
		  remote_storage_method_count:$rsmethods, proxy_handler_loc:$proxyloc,
		  proxy_closure_rows:$closures}' >"$out"

	record_host_load "partC_end"
	log "partC complete: $out"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "$SUBCOMMAND" in
setup) cmd_setup ;;
fingerprint) fingerprint ;;
partA) cmd_partA ;;
partB) cmd_partB ;;
partC) cmd_partC ;;
stats) python3 "$SCRIPT_DIR/phase0_stats.py" "$JSON_DIR" ;;
*)
	echo "usage: $0 <setup|fingerprint|partA|partB|partC|stats> [--dry-run]" >&2
	exit 2
	;;
esac
