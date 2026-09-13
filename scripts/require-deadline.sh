#!/usr/bin/env bash
# require-deadline.sh — enforce the universal per-input deadline convention on every
# fuzz target in this repo.
#
# WHY: native `go test -fuzz` has NO per-input timeout. A CPU-time / algorithmic-
# complexity DoS input therefore just drags throughput instead of being flagged as a
# crasher — UNLESS every target routes its `f.Fuzz` body through the shared
# `withinDeadline` helper (goroutine + select on a fixed budget). Convention alone
# rots; this lint makes it enforceable so an unguarded target cannot land.
#
# Two checks per target module (a directory under ROOT that contains a go.mod):
#   1. wrap coverage    — every top-level `func Fuzz*(... *testing.F)` calls
#                         withinDeadline() somewhere in its body. A target that
#                         genuinely cannot use it must carry a
#                         `//fuzzlint:no-deadline: <reason>` line inside the function.
#   2. helper conformance — a module that has at least one non-exempt target defines
#                         the canonical withinDeadline helper with the uniform
#                         `perInputDeadline = 2 * time.Second` budget (drift guard,
#                         since the modules are separate and copy the helper).
#
# Usage: scripts/require-deadline.sh [ROOT]      (ROOT defaults to "targets")
# Exit:  0 = all conform · 1 = violations · 2 = usage / no targets found
#
# Pure bash+awk+grep by design: it runs on a bare rig or in the local gate with no
# Go toolchain. Assumes gofmt'd source (top-level func braces at column 0).
set -euo pipefail

ROOT="${1:-targets}"

# Canonical helper fingerprint. These lines must appear verbatim (budget is
# whitespace-tolerant) in every module that owns a guarded target.
CANON_SIG='func withinDeadline(t *testing.T, fn func()) {'
CANON_AFTER='case <-time.After(perInputDeadline):'
CANON_BUDGET_RE='^const[[:space:]]+perInputDeadline[[:space:]]*=[[:space:]]*2[[:space:]]*\*[[:space:]]*time\.Second[[:space:]]*$'

if [ ! -d "$ROOT" ]; then
	echo "require-deadline: ROOT '$ROOT' is not a directory" >&2
	exit 2
fi

fail=0
found_any=0

# Emit "FuncName<TAB>WRAP|NOWRAP<TAB>OPTOUT|-" for each top-level Fuzz target in a file.
scan_file() {
	awk '
		/^func[ \t]+Fuzz[A-Za-z0-9_]*\(/ && /testing\.F\)/ {
			infunc = 1; fname = $2; sub(/\(.*/, "", fname); wrap = 0; opt = 0; next
		}
		infunc == 1 {
			if ($0 ~ /withinDeadline\(/)      wrap = 1
			if ($0 ~ /fuzzlint:no-deadline/)  opt = 1
			if ($0 ~ /^\}/) {
				printf "%s\t%s\t%s\n", fname, (wrap ? "WRAP" : "NOWRAP"), (opt ? "OPTOUT" : "-")
				infunc = 0
			}
		}
	' "$1"
}

while IFS= read -r gomod; do
	mod="$(dirname "$gomod")"

	# Collect every fuzz target across the module's *_test.go files.
	targets_out=""
	for tf in "$mod"/*_test.go; do
		[ -e "$tf" ] || continue
		out="$(scan_file "$tf")"
		[ -n "$out" ] && targets_out+="${out}"$'\n'
	done
	targets_out="${targets_out%$'\n'}"
	[ -z "$targets_out" ] && continue   # no fuzz targets here → nothing to enforce

	found_any=1
	count="$(printf '%s\n' "$targets_out" | grep -c .)"
	echo "== ${mod} (${count} fuzz target(s)) =="

	# Check 1: wrap coverage.
	nonexempt=0
	while IFS=$'\t' read -r fn state opt; do
		[ -z "$fn" ] && continue
		if [ "$opt" = "OPTOUT" ]; then
			echo "  opt   ${fn} (//fuzzlint:no-deadline)"
			continue
		fi
		nonexempt=$((nonexempt + 1))
		if [ "$state" = "WRAP" ]; then
			echo "  ok    ${fn}"
		else
			echo "  FAIL  ${fn} — f.Fuzz body does not call withinDeadline()"
			fail=1
		fi
	done <<< "$targets_out"

	# Check 2: helper conformance (only if the module owns a non-exempt target).
	if [ "$nonexempt" -gt 0 ]; then
		if ! grep -qsF -- "$CANON_SIG" "$mod"/*_test.go; then
			echo "  FAIL  helper — canonical withinDeadline signature not found"
			fail=1
		fi
		if ! grep -qsF -- "$CANON_AFTER" "$mod"/*_test.go; then
			echo "  FAIL  helper — deadline select ('${CANON_AFTER}') not found"
			fail=1
		fi
		if ! grep -qsE -- "$CANON_BUDGET_RE" "$mod"/*_test.go; then
			echo "  FAIL  helper — uniform budget 'perInputDeadline = 2 * time.Second' not found"
			fail=1
		fi
	fi
done < <(find "$ROOT" -maxdepth 2 -name go.mod | sort)

if [ "$found_any" -eq 0 ]; then
	echo "require-deadline: no fuzz targets found under '$ROOT'" >&2
	exit 2
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "require-deadline: FAILED — every Fuzz target must route its body through withinDeadline()."
	echo "  Fix: wrap the work in withinDeadline(t, func(){ ... }) and keep t.Fatal asserts outside it,"
	echo "  or, for a documented exception, add a '//fuzzlint:no-deadline: <reason>' line in the function."
	exit 1
fi
echo "require-deadline: OK — all fuzz targets enforce the per-input deadline."
