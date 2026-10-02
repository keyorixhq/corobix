#!/usr/bin/env bash
# triage-crasher.sh — automated crash triage (M11). Takes ONE reproducer file
# (the harvest guard's format: FINDINGS_DIR/<fn>/<ts>/<hash>, or any
# testdata/fuzz/<Func>/<hash> file — same "go test fuzz v1\n[]byte(...)" text
# format either way), and:
#
#   1. REPRODUCES it at HEAD, 3x (to also catch flaky), in a throwaway copy of
#      the module — never the caller's own checkout.
#   2. MINIMIZES it via go's own native engine: `go test -fuzz=^FUNC$` with the
#      reproducer already sitting in testdata/fuzz/FUNC/ hits it during
#      baseline seed evaluation and minimizes within the given budget — no
#      custom minimizer, no reimplementation of what the toolchain already
#      does correctly.
#   3. CLASSIFIES the failure (panic / oracle-violation / timeout / flaky)
#      from the captured `go test -v` output, never by re-guessing — panic
#      detection is literally `panic:` in the output, timeout is the
#      fuzzutil.Guard/withinDeadline "exceeded ... deadline" message text
#      those helpers already emit, oracle-violation is any other t.Fatalf
#      line (the target's OWN assertion message), flaky is an inconsistent
#      reproduce rate across the 3 runs.
#   4. DEDUPS by a key derived from (classification, stack-top-frame OR
#      oracle-message-first-line) against a ledger file, so re-running this on
#      the same underlying bug twice doesn't draft two findings.
#   5. DRAFTS a docs/findings/-shaped skeleton to a LOCAL OUTPUT DIR ONLY.
#
# NEVER FILES ANYTHING PUBLICLY ITSELF: no git add/commit/push, no `gh`, no
# network call of any kind. The draft is a starting point for a human to
# review, verify (this script's classification is a lead, not a verdict —
# same "the model is a lead generator, never gating" discipline as
# autofuzzgen/M10), and decide public-vs-keyorix-private placement before
# anything reaches docs/findings/ for real.
#
# Usage:
#   scripts/triage-crasher.sh --module <dir> --pkg <import-or-dir-path> \
#       --func <FuzzFuncName> --crasher <path-to-reproducer-file> \
#       [--reruns 3] [--minimize-time 30s] [--third-party] \
#       [--seen <ledger-tsv>] [--draft-out <dir>]
#
# Exit: 0 = triage completed (a draft was written, or this is a confirmed
# duplicate) · 1 = did not reproduce at HEAD after --reruns attempts (possibly
# already fixed, or genuinely flaky-to-the-point-of-unreproducible — draft
# still written, clearly labeled) · 2 = usage/tooling error.
set -euo pipefail

MODULE=""
PKG=""
FUNC=""
CRASHER=""
RERUNS=3
MINIMIZE_TIME="30s"
THIRD_PARTY=0
SEEN="$(dirname "$0")/.triage-seen.tsv"
DRAFT_OUT="./triage-drafts"

while [ $# -gt 0 ]; do
	case "$1" in
	--module) MODULE="$2"; shift 2 ;;
	--pkg) PKG="$2"; shift 2 ;;
	--func) FUNC="$2"; shift 2 ;;
	--crasher) CRASHER="$2"; shift 2 ;;
	--reruns) RERUNS="$2"; shift 2 ;;
	--minimize-time) MINIMIZE_TIME="$2"; shift 2 ;;
	--third-party) THIRD_PARTY=1; shift ;;
	--seen) SEEN="$2"; shift 2 ;;
	--draft-out) DRAFT_OUT="$2"; shift 2 ;;
	*) echo "triage-crasher: unknown arg '$1'" >&2; exit 2 ;;
	esac
done

for req in MODULE PKG FUNC CRASHER; do
	if [ -z "${!req}" ]; then
		# ${req,,} (bash 4+ case conversion) is not portable to bash 3.2 (macOS's
		# default /bin/bash) -- tr is.
		req_lower="$(printf '%s' "$req" | tr '[:upper:]' '[:lower:]')"
		echo "triage-crasher: --${req_lower} is required" >&2
		exit 2
	fi
done
[ -f "$MODULE/go.mod" ] || { echo "triage-crasher: '$MODULE/go.mod' not found" >&2; exit 2; }
[ -f "$CRASHER" ] || { echo "triage-crasher: crasher file '$CRASHER' not found" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/module"
cp -r "$MODULE" "$COPY"
rm -rf "$COPY/.git"

TDIR="$COPY/$PKG/testdata/fuzz/$FUNC"
mkdir -p "$TDIR"
CRASHER_BASENAME="$(basename "$CRASHER")"
cp "$CRASHER" "$TDIR/$CRASHER_BASENAME"

echo "== triage-crasher: reproducing $FUNC/$CRASHER_BASENAME at HEAD, ${RERUNS}x ==" >&2

FAILS=0
LAST_FAIL_LOG=""
for i in $(seq 1 "$RERUNS"); do
	LOG="$WORK/repro-$i.log"
	set +e
	( cd "$COPY/$PKG" && go test -run "^${FUNC}\$" -v . ) >"$LOG" 2>&1
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then
		FAILS=$((FAILS + 1))
		LAST_FAIL_LOG="$LOG"
	fi
done

CLASSIFICATION=""
DETAIL=""
if [ "$FAILS" -eq 0 ]; then
	CLASSIFICATION="not-reproducible"
	DETAIL="did not fail in any of $RERUNS runs at HEAD — possibly already fixed upstream, or the crasher no longer matches current corpus/seed wiring"
elif [ "$FAILS" -lt "$RERUNS" ]; then
	CLASSIFICATION="flaky"
	DETAIL="failed $FAILS/$RERUNS runs — inconsistent reproduction"
elif grep -q "^panic: " "$LAST_FAIL_LOG"; then
	CLASSIFICATION="panic"
	DETAIL="$(grep -m1 '^panic: ' "$LAST_FAIL_LOG")"
elif grep -qE "exceeded .* (deadline|budget)" "$LAST_FAIL_LOG"; then
	CLASSIFICATION="timeout"
	DETAIL="$(grep -m1 -E "exceeded .* (deadline|budget)" "$LAST_FAIL_LOG")"
elif grep -q -- "--- FAIL:" "$LAST_FAIL_LOG"; then
	CLASSIFICATION="oracle-violation"
	DETAIL="$(awk '/^ *[a-z_A-Z0-9./]+_test\.go:[0-9]+:/{print; exit}' "$LAST_FAIL_LOG")"
	[ -z "$DETAIL" ] && DETAIL="$(grep -m1 -- "--- FAIL:" "$LAST_FAIL_LOG")"
else
	CLASSIFICATION="unknown"
	DETAIL="failed but matched no known pattern — manual look required"
fi

echo "classification: $CLASSIFICATION" >&2
echo "detail: $DETAIL" >&2

# ---- minimize (only if it actually reproduces) ----
MINIMIZED_FILE=""
if [ "$FAILS" -gt 0 ] && [ "$CLASSIFICATION" != "flaky" ]; then
	echo "== minimizing (budget ${MINIMIZE_TIME}) ==" >&2
	BEFORE="$(find "$TDIR" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort)"
	set +e
	( cd "$COPY/$PKG" && go test -run "^${FUNC}\$" -fuzz "^${FUNC}\$" -fuzzminimizetime="$MINIMIZE_TIME" . ) >"$WORK/minimize.log" 2>&1
	set -e
	AFTER="$(find "$TDIR" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort)"
	NEWFILE="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -1)"
	if [ -n "$NEWFILE" ]; then
		MINIMIZED_FILE="$TDIR/$NEWFILE"
		echo "minimized reproducer: $NEWFILE ($(wc -c <"$MINIMIZED_FILE" | tr -d ' ') bytes, was $(wc -c <"$TDIR/$CRASHER_BASENAME" | tr -d ' ') bytes)" >&2
	else
		echo "no smaller reproducer found within budget — keeping original" >&2
	fi
fi
FINAL_REPRO="${MINIMIZED_FILE:-$TDIR/$CRASHER_BASENAME}"

# ---- dedup ----
dedup_source="$CLASSIFICATION|$FUNC|$DETAIL"
DEDUP_KEY="$(printf '%s' "$dedup_source" | shasum -a 256 | cut -c1-16)"
DUPLICATE=0
if [ -f "$SEEN" ] && grep -q "^${DEDUP_KEY}	" "$SEEN"; then
	DUPLICATE=1
	echo "DUPLICATE of an already-triaged finding (dedup key $DEDUP_KEY) — see $SEEN" >&2
else
	mkdir -p "$(dirname "$SEEN")"
	printf '%s\t%s\t%s\t%s\n' "$DEDUP_KEY" "$FUNC" "$CLASSIFICATION" "$DETAIL" >>"$SEEN"
fi

# ---- draft ----
mkdir -p "$DRAFT_OUT"
DRAFT="$DRAFT_OUT/DRAFT-${DEDUP_KEY}-${FUNC}.md"
{
	echo "# DRAFT — NOT FILED — human review required before this becomes a real finding"
	echo
	echo "Generated by \`scripts/triage-crasher.sh\`. This script never files, commits,"
	echo "or pushes anything — a human must verify the classification, decide"
	echo "public vs. \`keyorix-private\` placement, and do the actual filing."
	echo
	if [ "$THIRD_PARTY" -eq 1 ]; then
		echo "**THIRD-PARTY TARGET** — per standing embargo policy, this must go to"
		echo "\`keyorix-private\` only. Do not open a public issue/PR/doc with this content."
		echo
	fi
	echo "- func: \`$FUNC\` (\`$PKG\`)"
	echo "- classification: **$CLASSIFICATION**"
	echo "- dedup key: \`$DEDUP_KEY\`$( [ "$DUPLICATE" -eq 1 ] && echo ' — DUPLICATE, already triaged' )"
	echo "- reproduced: $FAILS/$RERUNS runs at HEAD"
	echo "- detail: \`$DETAIL\`"
	echo "- minimized reproducer: \`$(basename "$FINAL_REPRO")\` ($(wc -c <"$FINAL_REPRO" 2>/dev/null | tr -d ' ') bytes)"
	echo
	echo "## Reproduce"
	echo '```'
	echo "go test -run '^${FUNC}\$' -v ${PKG}"
	echo '```'
	echo "(with \`$(basename "$FINAL_REPRO")\` placed under \`testdata/fuzz/${FUNC}/\`)"
	echo
	echo "## Last failing run output (tail)"
	echo '```'
	if [ -n "$LAST_FAIL_LOG" ]; then
		tail -30 "$LAST_FAIL_LOG"
	else
		echo "(no failing run captured — see classification above)"
	fi
	echo '```'
} >"$DRAFT"

cp "$FINAL_REPRO" "$DRAFT_OUT/${DEDUP_KEY}-${FUNC}.repro" 2>/dev/null || true

echo "draft written: $DRAFT" >&2
if [ "$CLASSIFICATION" = "not-reproducible" ]; then
	exit 1
fi
exit 0
