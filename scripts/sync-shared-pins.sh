#!/usr/bin/env bash
# sync-shared-pins.sh — bump every targets/*/go.mod pin that drifted from
# keyorix main to keyorix's version, then prove the harness still builds and
# its seed corpus still passes. The fixing half of check-shared-pins.sh.
#
# For each target module: modules shared with keyorix main and pinned at a
# different version are moved with `go get mod@keyorix-version`, then
# `go mod tidy`, `go vet ./...` and `go test -count=1 ./...` (the seed corpus
# runs as ordinary tests) must pass. If any step fails, that target's go.mod
# and go.sum are restored byte-for-byte and the failure is reported — a bump
# that breaks the harness is never left half-applied.
#
# Pairs with a live row in scripts/pin-drift-allowlist.tsv are skipped (they
# are documented, reviewed divergence); expired rows are bumped like any
# other drift.
#
# Usage: scripts/sync-shared-pins.sh [--apply] [ROOT]    (ROOT defaults to "targets")
#   default is a dry run: print what would change, touch nothing.
#   KEYORIX_GOMOD_FILE=<path>   read keyorix's go.mod from a file (tests)
#   KEYORIX_REPO_URL=<url>      override the repo to clone
#                               (default https://github.com/keyorixhq/keyorix.git)
# Output (stdout): one "BUMP|SKIP|FAIL|OK <target> ..." line per decision, so a
# caller (the weekly workflow) can paste it into a PR description.
# Exit: 0 = nothing to do, or every bump verified · 1 = a target failed and was
# restored · 2 = usage/fetch error
set -euo pipefail

APPLY=0
ROOT="targets"
for arg in "$@"; do
	case "$arg" in
	--apply) APPLY=1 ;;
	*) ROOT="$arg" ;;
	esac
done
[ -d "$ROOT" ] || { echo "sync-shared-pins: ROOT '$ROOT' is not a directory" >&2; exit 2; }
command -v go >/dev/null || { echo "sync-shared-pins: go toolchain not found" >&2; exit 2; }

ROOT="$(cd "$ROOT" && pwd)"
ALLOWLIST="$(cd "$(dirname "$0")" && pwd)/pin-drift-allowlist.tsv"
today="$(date -u +%F)"

extract_versions() {
	awk '
		/^require[[:space:]]*\(/ { inblock = 1; next }
		inblock && /^\)/ { inblock = 0; next }
		inblock { if ($1 != "" && $2 ~ /^v/) print $1 "\t" $2; next }
		/^require[[:space:]]+[^[:space:](]/ { if ($2 != "" && $3 ~ /^v/) print $2 "\t" $3 }
	' "$1"
}

if [ -n "${KEYORIX_GOMOD_FILE:-}" ]; then
	KEYORIX_GOMOD="$KEYORIX_GOMOD_FILE"
	[ -f "$KEYORIX_GOMOD" ] || { echo "sync-shared-pins: KEYORIX_GOMOD_FILE '$KEYORIX_GOMOD_FILE' not found" >&2; exit 2; }
else
	CLONE_DIR="$(mktemp -d)"
	trap 'rm -rf "$CLONE_DIR"' EXIT
	git clone --depth=1 --branch main --quiet "${KEYORIX_REPO_URL:-https://github.com/keyorixhq/keyorix.git}" "$CLONE_DIR" >/dev/null 2>&1 ||
		{ echo "sync-shared-pins: could not clone keyorix main (network? auth?)" >&2; exit 2; }
	KEYORIX_GOMOD="$CLONE_DIR/go.mod"
fi
KEYORIX_VERS="$(extract_versions "$KEYORIX_GOMOD")"

allowlisted() { # module harness_version -> 0 when a live (not expired) row matches
	[ -f "$ALLOWLIST" ] || return 1
	awk -F'\t' -v m="$1" -v v="$2" -v t="$today" \
		'!/^#/ && NF >= 4 && $1 == m && $2 == v && $4 >= t { found = 1 } END { exit !found }' "$ALLOWLIST"
}

failed=0
while IFS= read -r gomod; do
	dir="$(dirname "$gomod")"
	name="${dir#"$ROOT"/}"
	bumps=()
	while IFS=$'\t' read -r hmod hver; do
		[ -z "$hmod" ] && continue
		kver="$(printf '%s\n' "$KEYORIX_VERS" | awk -F'\t' -v m="$hmod" '$1 == m { print $2; exit }')"
		[ -z "$kver" ] && continue
		[ "$kver" = "$hver" ] && continue
		if allowlisted "$hmod" "$hver"; then
			echo "SKIP $name $hmod $hver (documented divergence; keyorix has $kver)"
			continue
		fi
		bumps+=("$hmod $hver $kver")
	done < <(extract_versions "$gomod")

	if [ "${#bumps[@]}" -eq 0 ]; then
		echo "OK   $name already in sync"
		continue
	fi
	if [ "$APPLY" -eq 0 ]; then
		for b in "${bumps[@]}"; do read -r m o n <<<"$b"; echo "BUMP $name $m $o -> $n (dry run)"; done
		continue
	fi

	cp "$dir/go.mod" "$dir/go.mod.syncbak"
	[ -f "$dir/go.sum" ] && cp "$dir/go.sum" "$dir/go.sum.syncbak"
	restore() {
		mv -f "$dir/go.mod.syncbak" "$dir/go.mod"
		if [ -f "$dir/go.sum.syncbak" ]; then mv -f "$dir/go.sum.syncbak" "$dir/go.sum"; else rm -f "$dir/go.sum"; fi
	}
	ok=1
	log="$(mktemp)"
	for b in "${bumps[@]}"; do
		read -r m o n <<<"$b"
		(cd "$dir" && go get "$m@$n") >>"$log" 2>&1 || { echo "FAIL $name go get $m@$n failed: $(tail -1 "$log")"; ok=0; break; }
	done
	if [ "$ok" -eq 1 ]; then
		(cd "$dir" && go mod tidy && go vet ./... && go test -count=1 ./...) >>"$log" 2>&1 ||
			{ echo "FAIL $name build/vet/seed tests failed after bump: $(tail -3 "$log" | tr '\n' ' ' | cut -c1-300)"; ok=0; }
	fi
	if [ "$ok" -eq 1 ]; then
		rm -f "$dir/go.mod.syncbak" "$dir/go.sum.syncbak"
		for b in "${bumps[@]}"; do read -r m o n <<<"$b"; echo "BUMP $name $m $o -> $n (verified: tidy, vet, seed tests)"; done
	else
		restore
		echo "     $name restored to its previous go.mod/go.sum"
		failed=1
	fi
	rm -f "$log"
done < <(find "$ROOT" -maxdepth 2 -name go.mod | sort)

exit "$failed"
