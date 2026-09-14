#!/usr/bin/env bash
# coverage.sh — per-fuzz-target statement coverage, to tell genuine exhaustion (covered
# everything) apart from a low mutator ceiling (needs better seeds / a structure-aware
# harness, not more CPU).
#
#   - third-party-lib targets (in the map below): coverage of the LIBRARY under test
#     (-coverpkg scoped to that dependency).
#   - own-code targets (unmapped, e.g. dashdiag/keyorix internal packages): coverage of
#     the PACKAGE the target lives in (-cover, self).
#
# Coverage is read from `go test`'s own "coverage: N% of statements" line. Targets are
# discovered recursively, so this works for a targets/ tree OR a single own-code module.
#
# Usage:
#   scripts/coverage.sh [ROOT]                 # ROOT defaults to targets/; may be one module dir
#   FUZZ_CORPUS_DIR=/path scripts/coverage.sh  # fold a live corpus in as extra seeds
#
# FUZZ_CORPUS_DIR holds, per target, <FuzzName>/ or <project>/<FuzzName>/ (fuzz-corpus repo
# layout / a rig's $GOCACHE/fuzz/<module>/). Staged into testdata/fuzz/<FuzzName>/ for the
# run, then removed. Pure `go test`; no -fuzz, so it terminates. Needs the Go toolchain.
set -uo pipefail

ROOT="${1:-targets}"
CORPUS_DIR="${FUZZ_CORPUS_DIR:-}"

# Third-party targets → the dependency package(s) to measure. Unmapped ⇒ self-coverage.
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
	pkgdirs="$(find "$mod" -name '*_test.go' \
		-not -path '*/testdata/*' -not -path '*/vendor/*' -not -path '*/.git/*' \
		-not -path '*/.scratch/*' -not -path '*/.claude/*' -print0 2>/dev/null \
		| xargs -0 grep -lE '^func Fuzz' 2>/dev/null | xargs -r -n1 dirname | sort -u)"
	[ -z "$pkgdirs" ] && continue
	echo "== ${mod} =="
	printf "%-36s %-8s %s\n" "TARGET" "COV" "scope"
	while IFS= read -r pdir; do
		[ -z "$pdir" ] && continue
		rel="."; [ "$pdir" != "$mod" ] && rel="${pdir#"$mod"/}"
		fns="$(grep -hoE '^func Fuzz[A-Za-z0-9_]*\(' "$pdir"/*_test.go 2>/dev/null | sed -E 's/^func (Fuzz[A-Za-z0-9_]*)\(/\1/' | sort -u)"
		while IFS= read -r fn; do
			[ -z "$fn" ] && continue
			found=1
			cp="$(coverpkg_for "$fn")"
			if [ -n "$cp" ]; then covflag=(-coverpkg="$cp"); scope="lib"; else covflag=(-cover); scope="self:${rel}"; fi
			staged=""; src="$(corpus_src_for "$fn" || true)"
			if [ -n "$src" ]; then staged="$pdir/testdata/fuzz/$fn"; mkdir -p "$staged"; cp -n "$src"/* "$staged"/ 2>/dev/null || true; fi
			out="$( cd "$mod" && go test -run="^${fn}\$" "${covflag[@]}" "./$rel" 2>&1 )"; rc=$?
			pct="$(printf '%s\n' "$out" | grep -oE 'coverage: [0-9.]+%' | grep -oE '[0-9.]+%' | head -1)"
			if [ -n "$pct" ]; then printf "%-36s %-8s %s\n" "$fn" "$pct" "$scope"
			elif [ "$rc" -ne 0 ]; then printf "%-36s %-8s %s\n" "$fn" "CRASH?" "nonzero exit — check $fn"
			else printf "%-36s %-8s %s\n" "$fn" "?" "$scope (no coverage line)"; fi
			if [ -n "$src" ] && [ -n "$staged" ]; then for f in "$src"/*; do rm -f "$staged/$(basename "$f")"; done; rmdir "$staged" 2>/dev/null || true; fi
		done <<< "$fns"
	done <<< "$pkgdirs"
	echo
done < <(find "$ROOT" -maxdepth 2 -name go.mod | sort)

[ "$found" = 1 ] || { echo "coverage: no fuzz targets under '$ROOT'" >&2; exit 2; }
