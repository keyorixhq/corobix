#!/usr/bin/env bash
# replay-diff.sh — cross-version differential replay for one dependency of one
# targets/*/ module: build TWO copies of the module, pin the given dependency
# to an OLD and a NEW version in each, replay the SAME corpus (the module's
# committed testdata/fuzz/<FUNC>/ seeds, its f.Add seeds via `go test -run`,
# plus any extra reproducer files given with --corpus-file) through the named
# Fuzz function under both, and flag any input whose ACCEPT/REJECT or
# CRASH/NO-CRASH verdict differs between the two versions.
#
# WHY: a Dependabot bump changes behavior, not just a version string.
# scripts/check-shared-pins.sh (this repo) already catches a harness pinning a
# STALE version relative to keyorix; it does not tell you what actually
# changed for that dependency. #1895 in keyorix (digitorus/pkcs7 +
# digitorus/timestamp bumped past a real ber.go OOB-panic / BER-DoS pair) is
# exactly the shape this exists to make routine instead of a one-off manual
# verification: "reproducers panic/amplify on the old pin, clean on the new."
#
# SOUND ORACLE: `go test -run '^FUNC$' -v` replays each corpus entry as an
# ordinary subtest (this is what `go test -run` on a Fuzz function does —
# no `-fuzz` flag, no new mutation, just the recorded seeds). A subtest's
# PASS/FAIL is the target's OWN existing assertion (crash, deadline, or a
# reject/round-trip invariant already written into the *_test.go file) —
# this script adds no new judgment about what "correct" behavior is. It only
# asks: did changing ONE dependency version change that existing verdict for
# the SAME bytes? A flip is never a false positive in the "this script guessed
# wrong" sense — at most it inherits an unsound target invariant, which is a
# pre-existing property of the target, not of this script.
#
# SCOPE, STATED: this compares PASS/FAIL (accept/reject, crash/no-crash,
# deadline/no-deadline) per corpus entry. It does NOT compare decoded VALUES
# when both versions accept an input and the target has no reject/round-trip
# invariant (e.g. FuzzWebAuthnCredentialResponse, FuzzEtreeParse accept most
# well-formed input by design) — that would need per-target structured-output
# capture that does not exist today. Targets already written as reject-only or
# round-trip invariants (FuzzJWTParseIDToken, FuzzSAMLParseXMLResponse,
# FuzzTimestampParseRequest, FuzzGoXMLDSigReferenceBinding) get full value-level
# protection for free, because their PASS/FAIL already encodes the value-level
# property. This is a scope decision, not an oversight — see the module's own
# README for which targets carry which invariant.
#
# Usage:
#   crossversion/replay-diff.sh --module <targets/xxx> --dep <import/path> \
#       --old <version> --new <version> --func <FuzzFuncName> \
#       [--corpus-file <path> ...] [--out <report.md>]
#
# --dep/--old/--new may each be repeated (in matching order) when the bump moves
# more than one module together — e.g. digitorus/timestamp's go.mod requires a
# compatible digitorus/pkcs7, so downgrading pkcs7 alone without also moving
# timestamp back to its OLD pin breaks module resolution (verified: `go get`
# refuses/removes the mismatched requirement rather than silently building an
# invalid combination). All given (dep, old, new) triples are applied together
# in ONE `go get` per side, so partial/inconsistent resolution can't happen.
#
# Exit: 0 = no flips · 1 = flip(s) found (report written either way) · 2 = usage/tooling error
set -euo pipefail

MODULE=""
FUNC=""
OUT=""
DEPS=()
OLD_VERS=()
NEW_VERS=()
CORPUS_FILES=()

while [ $# -gt 0 ]; do
	case "$1" in
	--module) MODULE="$2"; shift 2 ;;
	--dep) DEPS+=("$2"); shift 2 ;;
	--old) OLD_VERS+=("$2"); shift 2 ;;
	--new) NEW_VERS+=("$2"); shift 2 ;;
	--func) FUNC="$2"; shift 2 ;;
	--corpus-file) CORPUS_FILES+=("$2"); shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	*) echo "replay-diff: unknown arg '$1'" >&2; exit 2 ;;
	esac
done

for req in MODULE FUNC; do
	if [ -z "${!req}" ]; then
		# ${req,,} (bash 4+ case conversion) is not portable to bash 3.2 (macOS's
		# default /bin/bash) -- tr is.
		req_lower="$(printf '%s' "$req" | tr '[:upper:]' '[:lower:]')"
		echo "replay-diff: --${req_lower} is required" >&2
		exit 2
	fi
done
if [ "${#DEPS[@]}" -eq 0 ] || [ "${#DEPS[@]}" -ne "${#OLD_VERS[@]}" ] || [ "${#DEPS[@]}" -ne "${#NEW_VERS[@]}" ]; then
	echo "replay-diff: --dep/--old/--new must each be given the same number of times (>=1)" >&2
	exit 2
fi
[ -f "$MODULE/go.mod" ] || { echo "replay-diff: '$MODULE/go.mod' not found" >&2; exit 2; }
# "${DEPS[@]}" is safe here (bash 3.2 raises "unbound variable" under set -u for
# a direct [@]/[*] expansion of a genuinely EMPTY array -- confirmed above this
# can never be empty at this point), kept as a plain expansion rather than the
# defensive "${DEPS[@]:-}" form used below for arrays that CAN legitimately be
# empty (CORPUS_FILES), so an accidental future loosening of the >=1 check above
# doesn't silently reintroduce the crash this comment is warning about.
for d in "${DEPS[@]}"; do
	if ! grep -q "$d" "$MODULE/go.mod"; then
		echo "replay-diff: '$d' is not a dependency of $MODULE/go.mod" >&2
		exit 2
	fi
done
[ -z "$OUT" ] && OUT="crossversion-report-$(basename "$MODULE")-${FUNC}.md"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OLD_DIR="$WORK/old"
NEW_DIR="$WORK/new"

for i in "${!DEPS[@]}"; do
	echo "== replay-diff: ${DEPS[$i]} ${OLD_VERS[$i]} -> ${NEW_VERS[$i]}, target $FUNC ($MODULE) ==" >&2
done

for side in old new; do
	dst="$WORK/$side"
	cp -r "$MODULE" "$dst"
	rm -rf "$dst/.git"
done

for f in "${CORPUS_FILES[@]:-}"; do
	[ -z "$f" ] && continue
	[ -f "$f" ] || { echo "replay-diff: --corpus-file '$f' not found" >&2; exit 2; }
	base="$(basename "$f")"
	for side in old new; do
		dir="$WORK/$side/testdata/fuzz/$FUNC"
		mkdir -p "$dir"
		cp "$f" "$dir/$base"
	done
done

pin_versions() {
	local dir="$1" side="$2"
	shift 2
	local specs=("$@")
	(
		cd "$dir"
		GOFLAGS=-mod=mod go get "${specs[@]}" >"$WORK/${side}-get.log" 2>&1
	) || {
		echo "replay-diff: 'go get ${specs[*]}' failed in $dir — see $WORK/${side}-get.log" >&2
		cat "$WORK/${side}-get.log" >&2
		exit 2
	}
}

OLD_SPECS=()
NEW_SPECS=()
for i in "${!DEPS[@]}"; do
	OLD_SPECS+=("${DEPS[$i]}@${OLD_VERS[$i]}")
	NEW_SPECS+=("${DEPS[$i]}@${NEW_VERS[$i]}")
done
pin_versions "$OLD_DIR" old "${OLD_SPECS[@]}"
pin_versions "$NEW_DIR" new "${NEW_SPECS[@]}"

run_side() {
	local dir="$1" log="$2"
	# Never let one side's failure abort the script before both sides have run —
	# a crash/panic in the target under test is data (an accept/reject flip
	# candidate), not a script error.
	set +e
	( cd "$dir" && go test -run "^${FUNC}\$" -v ./... ) >"$log" 2>&1
	local rc=$?
	set -e
	echo "$rc"
}

OLD_LOG="$WORK/old.log"
NEW_LOG="$WORK/new.log"
OLD_RC="$(run_side "$OLD_DIR" "$OLD_LOG")"
NEW_RC="$(run_side "$NEW_DIR" "$NEW_LOG")"

# extract_verdicts <log> — emit "subtest-name<TAB>PASS|FAIL" per `--- PASS:` /
# `--- FAIL:` line go test -v prints for each corpus subtest. `go test -v`
# indents per-subtest lines (`    --- PASS: FUNC/name (0.00s)`), so the match
# is on content, not column 0. The subtest name is the corpus filename, so the
# same name on both sides refers to the same bytes.
extract_verdicts() {
	awk -v fn="$FUNC" '
		$0 ~ "--- PASS: " fn "/" { split($3, a, "/"); print a[2] "\tPASS"; next }
		$0 ~ "--- FAIL: " fn "/" { split($3, a, "/"); print a[2] "\tFAIL"; next }
	' "$1"
}

extract_verdicts "$OLD_LOG" | sort >"$WORK/old.verdicts"
extract_verdicts "$NEW_LOG" | sort >"$WORK/new.verdicts"

FLIPS=0
{
	echo "# Cross-version differential report"
	echo
	echo "- module: \`$MODULE\`"
	for i in "${!DEPS[@]}"; do
		echo "- dependency: \`${DEPS[$i]}\` old=\`${OLD_VERS[$i]}\` new=\`${NEW_VERS[$i]}\`"
	done
	echo "- old side exit code: $OLD_RC · new side exit code: $NEW_RC"
	echo "- target: \`$FUNC\`"
	echo "- corpus entries compared: $(wc -l <"$WORK/old.verdicts" | tr -d ' ') (old) / $(wc -l <"$WORK/new.verdicts" | tr -d ' ') (new)"
	echo
	if [ "$OLD_RC" -ne 0 ] && [ "$NEW_RC" -eq 0 ]; then
		echo "**Whole-run signal**: old version's \`go test\` run itself failed (exit $OLD_RC) while new version's did not — consistent with a version-FIXED crash/hang not attributable to a single corpus subtest (e.g. an unrecovered panic in a spawned goroutine, which kills the whole test binary before per-subtest PASS/FAIL can print — see old.log below). Not a regression, but still a real behavior difference this bump introduced; worth a line in the release notes / catches ledger."
		echo
		FLIPS=1
	elif [ "$NEW_RC" -ne 0 ] && [ "$OLD_RC" -eq 0 ]; then
		echo "**Whole-run signal**: new version's \`go test\` run failed (exit $NEW_RC) while old version's did not — a REGRESSION introduced by this bump. See new.log below."
		echo
		FLIPS=1
	fi

	echo "## Per-input verdict flips"
	echo
	echo "| corpus entry | old | new |"
	echo "|---|---|---|"
	found_flip=0
	while IFS=$'\t' read -r name old_v; do
		[ -z "$name" ] && continue
		new_v="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$WORK/new.verdicts")"
		if [ -n "$new_v" ] && [ "$old_v" != "$new_v" ]; then
			echo "| \`$name\` | $old_v | $new_v |"
			found_flip=1
		fi
	done <"$WORK/old.verdicts"
	if [ "$found_flip" -eq 0 ]; then
		echo "| _(none)_ | | |"
	else
		FLIPS=1
	fi
	echo
	echo "## Entries only reproducible on one side"
	echo
	echo "(A build/tooling issue on one side, not a behavior flip — investigate separately.)"
	echo
	comm -23 <(cut -f1 "$WORK/old.verdicts") <(cut -f1 "$WORK/new.verdicts") | sed 's/^/- old-only: /'
	comm -13 <(cut -f1 "$WORK/old.verdicts") <(cut -f1 "$WORK/new.verdicts") | sed 's/^/- new-only: /'

	if [ "$OLD_RC" -ne 0 ] || [ "$NEW_RC" -ne 0 ]; then
		echo
		echo "## Log tails (whole-run failure context)"
		if [ "$OLD_RC" -ne 0 ]; then
			echo
			echo "### old.log (tail)"
			echo '```'
			tail -20 "$OLD_LOG"
			echo '```'
		fi
		if [ "$NEW_RC" -ne 0 ]; then
			echo
			echo "### new.log (tail)"
			echo '```'
			tail -20 "$NEW_LOG"
			echo '```'
		fi
	fi
} >"$OUT"

echo "replay-diff: report written to $OUT" >&2
if [ "$FLIPS" -ne 0 ]; then
	echo "replay-diff: FLIP(S) FOUND — see $OUT" >&2
	exit 1
fi
echo "replay-diff: no flips — old and new pins agree on every compared input" >&2
exit 0
