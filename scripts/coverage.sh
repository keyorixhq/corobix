#!/usr/bin/env bash
# coverage.sh — how much of each fuzzed third-party library does our corpus reach?
#
# "Saturated" (the fuzzer stopped finding new coverage) has two very different causes:
#   (a) we've covered essentially all reachable library code   → done, move on;
#   (b) we're stuck at a low ceiling the mutator can't break    → needs better seeds /
#       a structure-aware harness, NOT more CPU.
# This tells the two apart. For each Fuzz target it runs the SEED corpus (f.Add seeds
# + testdata/fuzz/<Func>/ + an optional live-corpus dir) with -coverpkg scoped to the
# LIBRARY under test, and reports that library's statement coverage (from `go test`'s
# own "coverage: N% of statements" line — robust across multi-package coverpkg sets).
#
# Usage:
#   scripts/coverage.sh [ROOT]                 # ROOT defaults to targets/
#   FUZZ_CORPUS_DIR=/path scripts/coverage.sh  # fold a live corpus in as extra seeds
#
# FUZZ_CORPUS_DIR contains, per target, either <FuzzName>/ directly or
# <project>/<FuzzName>/ (the fuzz-corpus repo layout / a rig's $GOCACHE/fuzz/<module>/).
# Staged files are copied into testdata/fuzz/<FuzzName>/ for the run, then removed
# (never committed). Pure `go test`; no -fuzz, so it terminates. Needs the Go toolchain.
set -uo pipefail

ROOT="${1:-targets}"
CORPUS_DIR="${FUZZ_CORPUS_DIR:-}"

coverpkg_for() {
	case "$1" in
		FuzzWebAuthnCredentialResponse)            echo "github.com/go-webauthn/webauthn/..." ;;
		FuzzWebAuthnXASN1|FuzzXASN1Differential)   echo "github.com/go-webauthn/x/..." ;;
		FuzzJWTParseIDToken|FuzzJWTVerifyReject)   echo "github.com/golang-jwt/jwt/v5/..." ;;
		FuzzSAMLParseXMLResponse)                  echo "github.com/crewjam/saml/...,github.com/russellhaering/goxmldsig/...,github.com/beevik/etree/..." ;;
		FuzzEtreeParse)                            echo "github.com/beevik/etree/..." ;;
		FuzzXMLEncDecrypt)                         echo "github.com/crewjam/saml/xmlenc/...,github.com/beevik/etree/..." ;;
		FuzzXMLRoundtripValidate|FuzzXMLRoundtripProperty) echo "github.com/mattermost/xml-roundtrip-validator/..." ;;
		FuzzTimestampParseRequest|FuzzTimestampParseResponse) echo "github.com/digitorus/timestamp/...,github.com/digitorus/pkcs7/..." ;;
		*) echo "" ;;
	esac
}

corpus_src_for() {
	local fn="$1" c
	[ -n "$CORPUS_DIR" ] || return 1
	for c in "$CORPUS_DIR/$fn" "$CORPUS_DIR"/*/"$fn"; do
		[ -d "$c" ] && { echo "$c"; return 0; }
	done
	return 1
}

command -v go >/dev/null || { echo "coverage: go toolchain not found" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "coverage: ROOT '$ROOT' not a directory" >&2; exit 2; }

found=0
while IFS= read -r gomod; do
	mod="$(dirname "$gomod")"
	fns="$(grep -hoE '^func Fuzz[A-Za-z0-9_]*\(' "$mod"/*_test.go 2>/dev/null | sed -E 's/^func (Fuzz[A-Za-z0-9_]*)\(/\1/' | sort -u)"
	[ -z "$fns" ] && continue
	found=1
	echo "== ${mod} =="
	printf "%-34s %-9s %s\n" "TARGET" "LIB-COV" "(extra corpus seeds)"
	while IFS= read -r fn; do
		[ -z "$fn" ] && continue
		cp="$(coverpkg_for "$fn")"
		if [ -z "$cp" ]; then
			printf "%-34s %-9s %s\n" "$fn" "n/a" "no coverpkg mapping"
			continue
		fi
		staged="" nstaged=0
		src="$(corpus_src_for "$fn" || true)"
		if [ -n "$src" ]; then
			staged="$mod/testdata/fuzz/$fn"
			mkdir -p "$staged"
			nstaged=$(find "$src" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
			cp -n "$src"/* "$staged"/ 2>/dev/null || true
		fi
		out="$( cd "$mod" && go test -run="^${fn}\$" -coverpkg="$cp" . 2>&1 )"
		rc=$?
		pct="$(printf '%s\n' "$out" | grep -oE 'coverage: [0-9.]+%' | grep -oE '[0-9.]+%' | head -1)"
		if [ -n "$pct" ]; then
			printf "%-34s %-9s %s\n" "$fn" "$pct" "${nstaged} file(s)"
		elif [ "$rc" -ne 0 ]; then
			printf "%-34s %-9s %s\n" "$fn" "CRASH?" "seed run exited nonzero — check $fn"
		else
			printf "%-34s %-9s %s\n" "$fn" "?" "no coverage line"
		fi
		if [ -n "$src" ] && [ -n "$staged" ]; then
			for f in "$src"/*; do rm -f "$staged/$(basename "$f")"; done
			rmdir "$staged" 2>/dev/null || true
		fi
	done <<< "$fns"
	echo
done < <(find "$ROOT" -maxdepth 2 -name go.mod | sort)

[ "$found" = 1 ] || { echo "coverage: no fuzz targets under '$ROOT'" >&2; exit 2; }
