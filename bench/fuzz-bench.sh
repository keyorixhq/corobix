#!/usr/bin/env bash
# fuzz-bench.sh — portable, resumable native-Go fuzzing benchmark.
#
# Usage: fuzz-bench.sh <role> [--dry-run] [--resume-ts <UTC-timestamp>]
#   role: keyorix | dashdiag
#
# Never touches production fuzz-runner state (fuzz.conf, systemd units,
# corpora, harness-state/harness-logs dirs). Everything this script reads
# from a live checkout it reads once, via a fresh `git clone` into $SCRATCH
# — clone never writes back into the source repo. All mutation (including
# TTF bug-revert) happens only inside $SCRATCH clones.
#
# See bench/README.md for full usage, what each metric means, and how to
# run this on a new rig (OCI Ampere A1 arm64, cloud spot).
set -uo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ROLE="${1:-}"
shift || true
DRY_RUN=0
RESUME_TS=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--resume-ts)
		RESUME_TS="${2:-}"
		shift 2
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done
case "$ROLE" in
keyorix | dashdiag) ;;
*)
	echo "usage: $0 <keyorix|dashdiag> [--dry-run] [--resume-ts <ts>]" >&2
	exit 2
	;;
esac

# ---------------------------------------------------------------------------
# Config (env-overridable)
# ---------------------------------------------------------------------------
GO_BIN="${GO_BIN:-/snap/go/current/bin/go}"
command -v "$GO_BIN" >/dev/null 2>&1 || GO_BIN="$(command -v go || true)"
[ -x "$GO_BIN" ] || {
	echo "no usable go binary found (GO_BIN=$GO_BIN)" >&2
	exit 2
}

SCRATCH="${SCRATCH:-$HOME/bench-work}"
KEYORIX_SRC="${KEYORIX_SRC:-/opt/keyorix-fuzz/keyorix}"
DASHDIAG_SRC="${DASHDIAG_SRC:-$HOME/proj/dashdiag}"
LIBSEXTRA_SRC="${LIBSEXTRA_SRC:-$HOME/proj/libs-extra-fuzz}"
COST_PER_HOUR="${COST_PER_HOUR:-}"
NPROC="$(nproc)"

if [ "$DRY_RUN" = 1 ]; then
	DUR_THROUGHPUT="${DUR_THROUGHPUT:-30s}"
	DUR_PARALLEL="${DUR_PARALLEL:-30s}"
	TTF_CAP_S="${TTF_CAP_S:-60}"
	TTF_REPS="${TTF_REPS:-1}"
	TTF_CONFIRM_CLEAN_S="${TTF_CONFIRM_CLEAN_S:-15}"
else
	DUR_THROUGHPUT="${DUR_THROUGHPUT:-15m}"
	DUR_PARALLEL="${DUR_PARALLEL:-5m}"
	TTF_CAP_S="${TTF_CAP_S:-3600}"
	TTF_REPS="${TTF_REPS:-5}"
	TTF_CONFIRM_CLEAN_S="${TTF_CONFIRM_CLEAN_S:-60}"
fi
PARALLEL_LEVELS="1 2 4 $NPROC"

HOSTNAME_TAG="$(hostname -s)"
TS="${RESUME_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_DIR="$SCRATCH/results/$HOSTNAME_TAG/$TS"
DONE_DIR="$RESULT_DIR/.done"
RAW_DIR="$RESULT_DIR/raw"
GOCACHE_ROOT="$SCRATCH/gocache/$TS"
SRC_ROOT="$SCRATCH/src/$TS"

mkdir -p "$RESULT_DIR" "$DONE_DIR" "$RAW_DIR" "$GOCACHE_ROOT" "$SRC_ROOT"

THROUGHPUT_CSV="$RESULT_DIR/throughput.csv"
PARALLEL_CSV="$RESULT_DIR/parallel.csv"
TTF_CSV="$RESULT_DIR/ttf.csv"
HW_TXT="$RESULT_DIR/hw.txt"
SUMMARY_MD="$RESULT_DIR/summary.md"
NOTES_FILE="$RESULT_DIR/notes.txt"

log() { echo "[$(date -u +%FT%TZ)] $*"; }
note() { echo "$*" >>"$NOTES_FILE"; }

# ---------------------------------------------------------------------------
# done-marker idempotency: one marker per (suite,target,param,rep)
# ---------------------------------------------------------------------------
done_marker() { printf '%s/%s' "$DONE_DIR" "$1"; }
is_done() { [ -f "$(done_marker "$1")" ]; }
mark_done() { : >"$(done_marker "$1")"; }

# ---------------------------------------------------------------------------
# duration parsing: "1h30m", "15m", "90s", bare integer seconds -> seconds
# ---------------------------------------------------------------------------
dur_to_secs() {
	local s="$1" total=0 n
	if [[ "$s" =~ ^[0-9]+$ ]]; then
		echo "$s"
		return
	fi
	n="$(printf '%s' "$s" | grep -oE '[0-9]+h' | grep -oE '[0-9]+')"
	[ -n "$n" ] && total=$((total + n * 3600))
	n="$(printf '%s' "$s" | grep -oE '[0-9]+m' | grep -oE '[0-9]+')"
	[ -n "$n" ] && total=$((total + n * 60))
	n="$(printf '%s' "$s" | grep -oE '[0-9]+s' | grep -oE '[0-9]+')"
	[ -n "$n" ] && total=$((total + n))
	echo "$total"
}

# ---------------------------------------------------------------------------
# parse the last "fuzz: elapsed: ..., execs: ..., new interesting: ..." line
# of a go test -fuzz log. Prints: elapsed_s,execs,execs_per_s,new_interesting,total_corpus
# execs_per_s is recomputed from execs/elapsed_s rather than trusting the
# printed instantaneous rate, which trails toward the tick average near the
# end of a run (same convention as fuzz-runner.sh's measured_exec_rate).
# ---------------------------------------------------------------------------
parse_fuzz_log() {
	local log="$1" line elapsed execs new_int total elapsed_s rate
	line="$(grep -aoE 'fuzz: elapsed: [0-9hms]+, execs: [0-9]+ \([0-9]+/sec\), new interesting: [0-9]+ \(total: [0-9]+\)' "$log" | tail -1)"
	if [ -z "$line" ]; then
		echo "0,0,0,0,0"
		return
	fi
	elapsed="$(echo "$line" | grep -oE 'elapsed: [0-9hms]+' | grep -oE '[0-9hms]+$')"
	execs="$(echo "$line" | grep -oE 'execs: [0-9]+' | grep -oE '[0-9]+')"
	new_int="$(echo "$line" | grep -oE 'new interesting: [0-9]+' | grep -oE '[0-9]+')"
	total="$(echo "$line" | grep -oE 'total: [0-9]+' | grep -oE '[0-9]+')"
	elapsed_s="$(dur_to_secs "$elapsed")"
	rate=0
	[ "$elapsed_s" -gt 0 ] && rate=$((execs / elapsed_s))
	printf '%s,%s,%s,%s,%s\n' "$elapsed_s" "$execs" "$rate" "$new_int" "$total"
}

# ---------------------------------------------------------------------------
# run "$@" capturing stdout+stderr to $1(logfile), peak RSS (kbytes) to
# $2(rssfile). Uses /usr/bin/time -v when present, else /proc polling.
# ---------------------------------------------------------------------------
run_with_rss() {
	local logfile="$1" rssfile="$2"
	shift 2
	local rc
	if command -v /usr/bin/time >/dev/null 2>&1; then
		/usr/bin/time -v "$@" >"$logfile" 2>&1
		rc=$?
		grep -aoE 'Maximum resident set size \(kbytes\): [0-9]+' "$logfile" | grep -oE '[0-9]+$' >"$rssfile" || true
		[ -s "$rssfile" ] || echo 0 >"$rssfile"
		return $rc
	fi
	"$@" >"$logfile" 2>&1 &
	local pid=$! peak=0 cur
	while kill -0 "$pid" 2>/dev/null; do
		cur="$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)"
		if [ -n "$cur" ] && [ "$cur" -gt "$peak" ] 2>/dev/null; then
			peak="$cur"
		fi
		sleep 2
	done
	wait "$pid"
	rc=$?
	echo "$peak" >"$rssfile"
	return $rc
}

# ---------------------------------------------------------------------------
# clone_pinned <source-dir> <dest-dir> <sha> — fresh, independent clone
# (never touches source repo) checked out detached at $sha.
# ---------------------------------------------------------------------------
clone_pinned() {
	local src="$1" dest="$2" sha="$3"
	rm -rf "$dest"
	git clone --quiet "$src" "$dest"
	git -C "$dest" checkout --quiet --detach "$sha"
}

# copy_pinned <source-dir> <dest-dir> — plain recursive copy for a source
# that isn't a git checkout at all (e.g. libs-extra-fuzz on the rig, which is
# a flat rsync/scp-deployed snapshot with no .git — DEPLOYED_FROM.txt is the
# only provenance it carries).
copy_pinned() {
	local src="$1" dest="$2"
	rm -rf "$dest"
	cp -r "$src" "$dest"
}

# record_provenance <dir> <label> — git SHA if $dir is a checkout, else the
# git_sha this deployed snapshot's DEPLOYED_FROM.txt records, else "unknown".
record_provenance() {
	local dir="$1" label="$2"
	if [ -d "$dir/.git" ]; then
		printf '%s: %s\n' "$label" "$(git -C "$dir" rev-parse HEAD)" >>"$HW_TXT"
	elif [ -f "$dir/DEPLOYED_FROM.txt" ]; then
		printf '%s (deployed snapshot, not a git checkout): %s\n' "$label" \
			"$(grep '^git_sha=' "$dir/DEPLOYED_FROM.txt")" >>"$HW_TXT"
	else
		printf '%s: unknown (no .git, no DEPLOYED_FROM.txt)\n' "$label" >>"$HW_TXT"
	fi
}

# ---------------------------------------------------------------------------
# fingerprint
# ---------------------------------------------------------------------------
fingerprint() {
	if is_done "fingerprint"; then
		return
	fi
	{
		echo "hostname: $(hostname)"
		echo "date_utc: $(date -u +%FT%TZ)"
		echo "role: $ROLE"
		echo "uname_m: $(uname -m)"
		echo "kernel: $(uname -srv)"
		echo "systemd_detect_virt: $(systemd-detect-virt 2>&1 || true)"
		echo "nproc: $NPROC"
		echo "go_version: $("$GO_BIN" version)"
		echo "cost_per_hour: ${COST_PER_HOUR:-unset}"
		echo "--- free -g ---"
		free -g
		echo "--- df scratch ---"
		df -h "$SCRATCH"
		echo "--- lscpu ---"
		if command -v lscpu >/dev/null 2>&1; then
			lscpu
		else
			echo "lscpu not available"
		fi
	} >"$HW_TXT"
	mark_done "fingerprint"
}

# ---------------------------------------------------------------------------
# Suite 2+3: throughput + parallel-scaling
# ---------------------------------------------------------------------------
run_throughput_target() {
	# run_throughput_target <module_dir> <pkg> <fn> <duration> <parallel> [skip_reason]
	local module_dir="$1" pkg="$2" fn="$3" duration="$4" parallel="$5" skip_reason="${6:-}"
	local key="throughput__${fn}__p${parallel}"
	if is_done "$key"; then
		return
	fi
	if [ -n "$skip_reason" ]; then
		echo "$HOSTNAME_TAG,$fn,$parallel,0,0,0,0,0,0,0,skipped:$skip_reason" >>"$THROUGHPUT_CSV"
		note "throughput: skipped $fn ($skip_reason)"
		mark_done "$key"
		return
	fi
	log "throughput: $fn -parallel=$parallel -fuzztime=$duration"
	# One GOCACHE shared across the whole run (isolated from production's own
	# GOCACHE, per the spec) rather than one per target: build/link time is
	# NOT part of go's reported fuzz "elapsed" clock (that starts only once
	# fuzzing itself begins), so a warm shared cache doesn't taint throughput
	# numbers — it only avoids re-paying the same stdlib/shared-dependency
	# compile cost on every single target and parallel level.
	local gocache="$GOCACHE_ROOT/shared"
	local logfile="$RAW_DIR/throughput-$fn-p$parallel.log"
	local rssfile="$RAW_DIR/throughput-$fn-p$parallel.rss"
	mkdir -p "$gocache"
	local t0=$SECONDS
	env -C "$module_dir" GOCACHE="$gocache" "$GO_BIN" test -c -o /dev/null "$pkg" >"${logfile}.build" 2>&1
	local build_s=$((SECONDS - t0))
	run_with_rss "$logfile" "$rssfile" env -C "$module_dir" GOCACHE="$gocache" "$GO_BIN" test "$pkg" \
		-run "^${fn}\$" -fuzz "^${fn}\$" -fuzztime "$duration" -parallel "$parallel" -v
	local parsed peak_rss
	parsed="$(parse_fuzz_log "$logfile")"
	peak_rss="$(cat "$rssfile" 2>/dev/null || echo 0)"
	echo "$HOSTNAME_TAG,$fn,$parallel,$parsed,$peak_rss,$build_s," >>"$THROUGHPUT_CSV"
	mark_done "$key"
}

run_parallel_target() {
	# run_parallel_target <module_dir> <pkg> <fn>
	local module_dir="$1" pkg="$2" fn="$3" p
	for p in $PARALLEL_LEVELS; do
		local key="parallel__${fn}__p${p}"
		if is_done "$key"; then
			continue
		fi
		log "parallel-scaling: $fn -parallel=$p -fuzztime=$DUR_PARALLEL"
		local gocache="$GOCACHE_ROOT/shared" # see run_throughput_target for why this is shared
		local logfile="$RAW_DIR/parallel-$fn-p$p.log"
		mkdir -p "$gocache"
		env -C "$module_dir" GOCACHE="$gocache" "$GO_BIN" test "$pkg" \
			-run "^${fn}\$" -fuzz "^${fn}\$" -fuzztime "$DUR_PARALLEL" -parallel "$p" -v >"$logfile" 2>&1
		local parsed execs_per_s per_worker
		parsed="$(parse_fuzz_log "$logfile")"
		execs_per_s="$(echo "$parsed" | cut -d, -f3)"
		per_worker=0
		[ "$p" -gt 0 ] && per_worker=$((execs_per_s / p))
		echo "$HOSTNAME_TAG,$fn,$p,$parsed,$per_worker" >>"$PARALLEL_CSV"
		mark_done "$key"
	done
}

# ---------------------------------------------------------------------------
# Suite 4: time-to-find. Each TTF case gets its own scratch clone with a
# known-fixed security bug reverted (or, for the libs-extra case, an old
# vulnerable dependency pin restored). Crashers stay inside $SCRATCH only;
# nothing here is ever committed or pushed.
# ---------------------------------------------------------------------------
ttf_revert_keyorix_commit() {
	# ttf_revert_keyorix_commit <case_dir> <fix_sha> — revert every file that
	# commit MODIFIED (not ADDED), restoring pre-fix behaviour while leaving
	# the fix's own new fuzz-test file(s) in place so the target still exists.
	# Never silently drop a failed per-file revert: a later commit editing the
	# SAME shared file (docs/security-closures.tsv, targets.conf — anything
	# appended-to by many unrelated PRs) can make an old patch fail to reverse-
	# apply cleanly even though the file that actually matters reverted fine.
	# That's tolerable for a bookkeeping file (the post-revert build check is
	# the real safety net for anything that changes behaviour) but it must be
	# recorded, not just left in stderr for someone to notice by accident.
	local dir="$1" fix_sha="$2" f
	git -C "$dir" diff --name-status "${fix_sha}^1" "$fix_sha" | awk '$1=="M"{print $2}' |
		while IFS= read -r f; do
			if ! git -C "$dir" show "$fix_sha" -- "$f" | git -C "$dir" apply -R 2>>"$NOTES_FILE"; then
				note "ttf: revert of $fix_sha did not cleanly apply to $f (likely edited again by a later commit) — left as-is; harmless unless \$f changes program behaviour, see post-revert build check"
			fi
		done
}

ttf_reset_corpus_git() {
	# wipe any discovered/crash corpus from the previous rep, keep checked-in seeds
	local dir="$1" pkg_dir="$2" fn="$3"
	git -C "$dir" clean -fdxq -- "${pkg_dir#./}/testdata/fuzz/$fn" 2>/dev/null || true
}

ttf_reset_corpus_copy() {
	# same job as ttf_reset_corpus_git, for a case_dir with no .git to clean
	# against: snapshot the checked-in seed corpus on first call (once, next
	# to case_dir so it survives repeated resets), then restore it every call.
	local dir="$1" pkg_dir="$2" fn="$3"
	local corpus_dir="$dir/${pkg_dir#./}/testdata/fuzz/$fn"
	local snap="${dir}.corpus-snapshot"
	if [ ! -d "$snap" ]; then
		mkdir -p "$snap"
		[ -d "$corpus_dir" ] && cp -r "$corpus_dir" "$snap/seed"
	fi
	rm -rf "$corpus_dir"
	if [ -d "$snap/seed" ]; then
		mkdir -p "$(dirname "$corpus_dir")"
		cp -r "$snap/seed" "$corpus_dir"
	fi
}

ttf_run_case() {
	# ttf_run_case <case_name> <pkg> <fn> <pkg_dir_for_clean> <materialize_fn> <revert_fn> <reset_fn>
	local case_name="$1" pkg="$2" fn="$3" pkg_dir="$4" materialize_fn="$5" revert_fn="$6" reset_fn="$7"
	local case_dir="$SRC_ROOT/ttf-$case_name"
	local gocache="$GOCACHE_ROOT/ttf-$case_name"
	mkdir -p "$gocache"

	if ! is_done "ttf_setup__${case_name}"; then
		"$materialize_fn" "$case_dir"
		record_provenance "$case_dir" "ttf_${case_name}_pinned"

		# confirm the UNREVERTED target runs clean before introducing the bug,
		# so "found" downstream really means the restored bug and not noise.
		local prelog="$RAW_DIR/ttf-$case_name-preconfirm.log"
		env -C "$case_dir" GOCACHE="$gocache" timeout "$((TTF_CONFIRM_CLEAN_S + 30))" \
			"$GO_BIN" test "$pkg" -run "^${fn}\$" -fuzz "^${fn}\$" -fuzztime "${TTF_CONFIRM_CLEAN_S}s" -parallel 2 -v >"$prelog" 2>&1
		if grep -aq -- '--- FAIL' "$prelog"; then
			note "ttf: $case_name FAILS BEFORE REVERT — skipping (fixture is not clean pre-revert)"
			mark_done "ttf_setup__${case_name}"
			mark_done "ttf_skip__${case_name}"
			return
		fi

		"$revert_fn" "$case_dir"
		record_provenance "$case_dir" "ttf_${case_name}_after_revert_note"

		# A revert built from "every file the fix commit MODIFIED" can produce
		# code that doesn't compile when the fix's own regression test calls a
		# symbol the SAME commit introduced (the test isn't just exercising old
		# code — it exercises the new recovery/fix path directly). Confirm the
		# reverted tree actually builds before trusting any TTF timing from it;
		# a build failure must never be silently read as "bug not found".
		local buildlog="$RAW_DIR/ttf-$case_name-postrevert-build.log"
		if ! env -C "$case_dir" GOCACHE="$gocache" "$GO_BIN" test -c -o /dev/null "$pkg" >"$buildlog" 2>&1; then
			note "ttf: $case_name DOES NOT COMPILE AFTER REVERT — skipping (the fix's own regression test likely calls a symbol the fix itself introduced; see raw/$(basename "$buildlog")). Not mechanically revertible by file-level revert; needs a hand-authored partial patch if this case matters."
			mark_done "ttf_setup__${case_name}"
			mark_done "ttf_skip__${case_name}"
			return
		fi
		mark_done "ttf_setup__${case_name}"
	fi
	if is_done "ttf_skip__${case_name}"; then
		return
	fi

	local rep
	for rep in $(seq 1 "$TTF_REPS"); do
		local key="ttf__${case_name}__rep${rep}"
		if is_done "$key"; then
			continue
		fi
		"$reset_fn" "$case_dir" "$pkg_dir" "$fn"
		log "ttf: $case_name rep $rep/$TTF_REPS (cap ${TTF_CAP_S}s)"
		local logfile="$RAW_DIR/ttf-$case_name-rep$rep.log"
		local t0=$SECONDS
		env -C "$case_dir" GOCACHE="$gocache" timeout "$((TTF_CAP_S + 30))" \
			"$GO_BIN" test "$pkg" -run "^${fn}\$" -fuzz "^${fn}\$" -fuzztime "${TTF_CAP_S}s" -parallel "$NPROC" -v >"$logfile" 2>&1
		local elapsed=$((SECONDS - t0))
		if grep -aq -- '--- FAIL' "$logfile"; then
			echo "$HOSTNAME_TAG,$case_name,$rep,true,$elapsed,$TTF_CAP_S" >>"$TTF_CSV"
		else
			echo "$HOSTNAME_TAG,$case_name,$rep,false,$TTF_CAP_S,$TTF_CAP_S" >>"$TTF_CSV"
		fi
		mark_done "$key"
	done
}

ttf_setup_libsextra_old_pkcs7() {
	local dir="$1"
	env -C "$dir" "$GO_BIN" mod edit -require=github.com/digitorus/pkcs7@v0.0.0-20230713084857-e76b763bdc49
	env -C "$dir" "$GO_BIN" mod tidy
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
: >"$THROUGHPUT_CSV" 2>/dev/null || true
[ -s "$THROUGHPUT_CSV" ] || echo "rig,target,parallel,elapsed_s,execs,execs_per_s,new_interesting,total_corpus,peak_rss_kb,build_s,note" >"$THROUGHPUT_CSV"
[ -s "$PARALLEL_CSV" ] || echo "rig,target,parallel,elapsed_s,execs,execs_per_s,new_interesting,total_corpus,execs_per_s_per_worker" >"$PARALLEL_CSV"
[ -s "$TTF_CSV" ] || echo "rig,case,rep,found,seconds,cap_s" >"$TTF_CSV"

fingerprint

if [ "$ROLE" = keyorix ]; then
	KEYORIX_DIR="$SRC_ROOT/keyorix"
	if ! is_done "clone__keyorix"; then
		PINNED_SHA="$(git -C "$KEYORIX_SRC" rev-parse HEAD)"
		clone_pinned "$KEYORIX_SRC" "$KEYORIX_DIR" "$PINNED_SHA"
		record_provenance "$KEYORIX_DIR" "keyorix_pinned"
		mark_done "clone__keyorix"
	fi

	# KEYORIX_TEST_PG_DSN only lives in the production fuzz.conf, which this
	# script deliberately never sources (hard rule: don't touch fuzz.conf).
	# Default to the known-local PG this rig's fuzz.conf points at; on a rig
	# without that listener (or the env var already set to something else)
	# the TCP probe below decides, so this stays portable to OCI/spot too.
	KEYORIX_TEST_PG_DSN="${KEYORIX_TEST_PG_DSN:-host=127.0.0.1 port=59432 user=fuzz dbname=fuzz sslmode=disable}"
	PG_OK=0
	if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/59432' 2>/dev/null; then
		PG_OK=1
		export KEYORIX_TEST_PG_DSN
	fi

	run_throughput_target "$KEYORIX_DIR" ./internal/core FuzzPATRestrictionAllows "$DUR_THROUGHPUT" "$NPROC"
	run_throughput_target "$KEYORIX_DIR" ./internal/encryption FuzzAEADTamperRoundTrip "$DUR_THROUGHPUT" "$NPROC"
	run_throughput_target "$KEYORIX_DIR" ./internal/encryption FuzzKEKRotationCrashConsistency "$DUR_THROUGHPUT" "$NPROC"
	if [ "$PG_OK" = 1 ]; then
		run_throughput_target "$KEYORIX_DIR" ./internal/storage/store FuzzStorageBackendDifferential "$DUR_THROUGHPUT" "$NPROC"
	else
		run_throughput_target "$KEYORIX_DIR" ./internal/storage/store FuzzStorageBackendDifferential "$DUR_THROUGHPUT" "$NPROC" "no PG DSN available"
	fi

	run_parallel_target "$KEYORIX_DIR" ./internal/core FuzzPATRestrictionAllows
	run_parallel_target "$KEYORIX_DIR" ./internal/encryption FuzzAEADTamperRoundTrip

	ttf_materialize_keyorix() { clone_pinned "$KEYORIX_SRC" "$1" "$(git -C "$KEYORIX_SRC" rev-parse HEAD)"; }

	ttf_revert_keyorix_commit_case_a() { ttf_revert_keyorix_commit "$1" daf8b889e110d4c8e11b1ca2df7f4202e793c03d; }
	ttf_run_case case_a__FuzzParseResponse_pr1889 \
		./internal/saml FuzzParseResponse ./internal/saml \
		'ttf_materialize_keyorix' 'ttf_revert_keyorix_commit_case_a' 'ttf_reset_corpus_git'

	ttf_revert_keyorix_commit_case_b() { ttf_revert_keyorix_commit "$1" b27f0095d0b07aa5f75d7c4b697ea211ffab3f5e; }
	ttf_run_case case_b__FuzzDEKSweepCrashConsistency_pr1918 \
		./internal/encryption FuzzDEKSweepCrashConsistency ./internal/encryption \
		'ttf_materialize_keyorix' 'ttf_revert_keyorix_commit_case_b' 'ttf_reset_corpus_git'
fi

if [ "$ROLE" = dashdiag ]; then
	DASHDIAG_DIR="$SRC_ROOT/dashdiag"
	if ! is_done "clone__dashdiag"; then
		PINNED_SHA="$(git -C "$DASHDIAG_SRC" rev-parse HEAD)"
		clone_pinned "$DASHDIAG_SRC" "$DASHDIAG_DIR" "$PINNED_SHA"
		record_provenance "$DASHDIAG_DIR" "dashdiag_pinned"
		mark_done "clone__dashdiag"
	fi
	note "dashdiag collector chosen: FuzzParseSystemdTime (internal/collectors/fuzz_time_parsers_linux_test.go) — pure string parser, no host syscalls, fast+stable"
	run_throughput_target "$DASHDIAG_DIR" ./internal/collectors FuzzParseSystemdTime "$DUR_THROUGHPUT" "$NPROC"

	# libs-extra-fuzz is a flat rsync/scp-deployed snapshot on this rig (see
	# DEPLOYED_FROM.txt), not a git checkout — copy_pinned, not clone_pinned.
	ttf_materialize_libsextra() { copy_pinned "$LIBSEXTRA_SRC" "$1"; }
	ttf_run_case case_c__FuzzTimestampParseResponse_pkcs7 \
		. FuzzTimestampParseResponse . \
		'ttf_materialize_libsextra' 'ttf_setup_libsextra_old_pkcs7' 'ttf_reset_corpus_copy'
fi

# ---------------------------------------------------------------------------
# summary.md
# ---------------------------------------------------------------------------
{
	echo "# Fuzz benchmark — $HOSTNAME_TAG ($TS)"
	echo
	echo "Role: $ROLE   Dry run: $([ "$DRY_RUN" = 1 ] && echo yes || echo no)"
	echo
	echo "## Throughput"
	echo
	echo "| target | parallel | execs/s | execs/s/core | new_interesting | total_corpus | peak_rss_kb | build_s |"
	echo "|---|---|---|---|---|---|---|---|"
	tail -n +2 "$THROUGHPUT_CSV" | while IFS=, read -r _ target parallel _ _ execs_per_s new_interesting total_corpus peak_rss build_s notecol; do
		per_core=0
		[ "$NPROC" -gt 0 ] 2>/dev/null && per_core=$((execs_per_s / NPROC))
		echo "| $target | $parallel | $execs_per_s | $per_core | $new_interesting | $total_corpus | $peak_rss | $build_s |${notecol:+ ($notecol)}"
	done
	echo
	echo "## Parallel scaling"
	echo
	echo "| target | parallel | execs/s | execs/s/worker |"
	echo "|---|---|---|---|"
	tail -n +2 "$PARALLEL_CSV" | while IFS=, read -r _ target parallel _ _ execs_per_s _ _ per_worker; do
		echo "| $target | $parallel | $execs_per_s | $per_worker |"
	done
	echo
	echo "## Time-to-find (median over reps, seconds; cap = $TTF_CAP_S s)"
	echo
	echo "| case | reps found | median seconds |"
	echo "|---|---|---|"
	for case_name in case_a__FuzzParseResponse_pr1889 case_b__FuzzDEKSweepCrashConsistency_pr1918 case_c__FuzzTimestampParseResponse_pkcs7; do
		grep -q ",$case_name," "$TTF_CSV" 2>/dev/null || continue
		vals="$(grep ",$case_name," "$TTF_CSV" | awk -F, '{print $5}' | sort -n)"
		n_found="$(grep -c ",$case_name,true," "$TTF_CSV" 2>/dev/null | tr -d ' ')"
		n_total="$(grep -c ",$case_name," "$TTF_CSV" | tr -d ' ')"
		median="$(echo "$vals" | awk '{a[NR]=$1} END{if(NR==0){print "n/a"}else{print a[int((NR+1)/2)]}}')"
		echo "| $case_name | $n_found/$n_total | $median |"
	done
	echo
	echo "## Notes"
	echo
	echo "- runner paused: production fuzz services were confirmed inactive before benchmarking (see hw.txt)"
	echo "- PG DSN available: $([ "${PG_OK:-0}" = 1 ] && echo yes || echo no)"
	if [ -f "$NOTES_FILE" ]; then
		sed 's/^/- /' "$NOTES_FILE"
	fi
} >"$SUMMARY_MD"

log "done. results in $RESULT_DIR"
