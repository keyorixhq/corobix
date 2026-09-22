#!/usr/bin/env bash
# check-shared-pins.sh — fail when a harness target module's go.mod pins a
# library at a DIFFERENT version than keyorix main ships for that same
# library, unless the divergence is explicitly allowlisted and not overdue
# for review.
#
# WHY: targets/libs-extra fuzzed digitorus/pkcs7 at a ~3-year-old pin and
# digitorus/timestamp at a ~4-month-old pin while keyorix had already moved
# to the Sept 14 2026 versions (both fixing a real ber.go OOB panic) — nobody
# noticed because nothing checked. This makes that class of drift loud
# instead of silent.
#
# Compares every module in targets/*/go.mod against the SAME module in
# keyorix main's go.mod (fetched fresh, not from a local checkout — the rig
# running this and the keyorix checkout it fuzzes are different things, and
# staleness in either one should not hide staleness in the other). A module
# name shared by both, pinned to different versions, is drift — unless
# scripts/pin-drift-allowlist.tsv carries a row for that exact
# (module, harness_version) pair whose review date has not passed.
#
# Usage: scripts/check-shared-pins.sh [ROOT]      (ROOT defaults to "targets")
#   KEYORIX_GOMOD_FILE=<path>   read keyorix's go.mod from this file instead
#                               of cloning (tests; also usable on a rig with
#                               no outbound git access — see --warn-only)
#   KEYORIX_REPO_URL=<url>      override the repo to clone
#                               (default https://github.com/keyorixhq/keyorix.git)
#   --warn-only                 print findings but always exit 0 (used at rig
#                               startup — a drifted checkout should be visible
#                               in the run log, not block the rig from fuzzing)
# Exit: 0 = clean (or --warn-only) · 1 = drift found · 2 = usage/fetch error
#
# Pure bash+awk+grep by design, same rationale as require-deadline.sh: must
# run on a bare rig with no Go toolchain assumed (a real go.mod parse would
# need `go list -m`, i.e. a full toolchain + module download just to read a
# version string).
set -euo pipefail

WARN_ONLY=0
ROOT="targets"
for arg in "$@"; do
	case "$arg" in
	--warn-only) WARN_ONLY=1 ;;
	*) ROOT="$arg" ;;
	esac
done

if [ ! -d "$ROOT" ]; then
	echo "check-shared-pins: ROOT '$ROOT' is not a directory" >&2
	exit 2
fi

# extract_versions <go.mod path> — emit "module<TAB>version" for every
# required module, single-line (`require mod v1.2.3`) or block
# (`require (\n\tmod v1.2.3 // indirect\n)`) form. Skips `go`/`module`/`toolchain`
# directive lines and blank/comment lines by construction (neither pattern
# matches them).
extract_versions() {
	awk '
		/^require[[:space:]]*\(/ { inblock = 1; next }
		inblock && /^\)/ { inblock = 0; next }
		inblock {
			if ($1 != "" && $2 ~ /^v/) print $1 "\t" $2
			next
		}
		/^require[[:space:]]+[^[:space:](]/ {
			if ($2 != "" && $3 ~ /^v/) print $2 "\t" $3
		}
	' "$1"
}

# Fetch (or read) keyorix main's go.mod.
KEYORIX_GOMOD_TMP=""
if [ -n "${KEYORIX_GOMOD_FILE:-}" ]; then
	KEYORIX_GOMOD="$KEYORIX_GOMOD_FILE"
	[ -f "$KEYORIX_GOMOD" ] || { echo "check-shared-pins: KEYORIX_GOMOD_FILE '$KEYORIX_GOMOD_FILE' not found" >&2; exit 2; }
else
	KEYORIX_REPO_URL="${KEYORIX_REPO_URL:-https://github.com/keyorixhq/keyorix.git}"
	CLONE_DIR="$(mktemp -d)"
	KEYORIX_GOMOD_TMP="$CLONE_DIR"
	trap 'rm -rf "$KEYORIX_GOMOD_TMP"' EXIT
	if ! git clone --depth=1 --branch main --quiet "$KEYORIX_REPO_URL" "$CLONE_DIR" >/dev/null 2>&1; then
		echo "check-shared-pins: could not clone $KEYORIX_REPO_URL (network? auth?)" >&2
		[ "$WARN_ONLY" -eq 1 ] && { echo "check-shared-pins: --warn-only, continuing without the check" >&2; exit 0; }
		exit 2
	fi
	KEYORIX_GOMOD="$CLONE_DIR/go.mod"
fi

KEYORIX_VERS="$(extract_versions "$KEYORIX_GOMOD")"

ALLOWLIST="$(dirname "$0")/pin-drift-allowlist.tsv"
today="$(date -u +%F)"

fail=0
checked_any=0

while IFS= read -r gomod; do
	mod_dir="$(dirname "$gomod")"
	echo "== ${mod_dir} =="
	harness_vers="$(extract_versions "$gomod")"
	[ -z "$harness_vers" ] && { echo "  (no require entries)"; continue; }

	while IFS=$'\t' read -r hmod hver; do
		[ -z "$hmod" ] && continue
		kver="$(printf '%s\n' "$KEYORIX_VERS" | awk -F'\t' -v m="$hmod" '$1 == m { print $2; exit }')"
		[ -z "$kver" ] && continue   # not a module keyorix pins at all — nothing to compare
		checked_any=1
		if [ "$kver" = "$hver" ]; then
			echo "  ok    ${hmod} @ ${hver}"
			continue
		fi

		# Drift. Allowlisted?
		entry=""
		if [ -f "$ALLOWLIST" ]; then
			entry="$(awk -F'\t' -v m="$hmod" -v v="$hver" \
				'!/^#/ && NF >= 4 && $1 == m && $2 == v { print; exit }' "$ALLOWLIST")"
		fi
		if [ -z "$entry" ]; then
			echo "  FAIL  ${hmod}: harness has ${hver}, keyorix main has ${kver} (undocumented drift)"
			fail=1
			continue
		fi
		review_date="$(printf '%s' "$entry" | awk -F'\t' '{print $4}')"
		reason="$(printf '%s' "$entry" | awk -F'\t' '{print $3}')"
		if [[ "$review_date" < "$today" ]]; then
			echo "  FAIL  ${hmod} @ ${hver} (keyorix: ${kver}): allowlist entry expired (review date ${review_date} < ${today}) — reason on file: ${reason}"
			fail=1
		else
			echo "  info  ${hmod} @ ${hver} (keyorix: ${kver}): documented divergence, reviewed through ${review_date} — ${reason}"
		fi
	done <<<"$harness_vers"
done < <(find "$ROOT" -maxdepth 2 -name go.mod | sort)

if [ "$checked_any" -eq 0 ]; then
	echo "check-shared-pins: no module shared between any targets/*/go.mod and keyorix's go.mod — nothing to check" >&2
	exit 2
fi

echo
if [ "$fail" -ne 0 ]; then
	if [ "$WARN_ONLY" -eq 1 ]; then
		echo "check-shared-pins: WARNING — drift found above (continuing, --warn-only)" >&2
		exit 0
	fi
	echo "check-shared-pins: FAILED — bump the harness pin to match keyorix, or add a reviewed"
	echo "  allowlist row (module, harness version, reason, review date) to $ALLOWLIST."
	exit 1
fi
echo "check-shared-pins: OK — every module shared with keyorix main is pinned to the same version (or a live-reviewed allowlist entry)."
