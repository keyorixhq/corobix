#!/usr/bin/env bash
# detect-cgo.sh: find cgo in your build graph before you fuzz it (or ship it).
# Usage: detect-cgo.sh [module-dir] [package-pattern...]
#   module-dir       defaults to .
#   package-pattern  defaults to ./...
#
# Only flags third-party, non-stdlib cgo (a real C dependency you chose to
# take on). Stdlib's own small cgo shims (net's system resolver, os/user) are
# excluded on purpose -- most of them aren't even in the binary under
# CGO_ENABLED=0, and they are not the "do you really want this" question
# this script exists to ask.
set -euo pipefail
MODDIR="${1:-.}"
if [ "$#" -gt 0 ]; then shift; fi
PATTERNS=("$@")
[ "${#PATTERNS[@]}" -eq 0 ] && PATTERNS=(./...)

cd "$MODDIR"
MODULE="$(go list -m 2>/dev/null)" || { echo "detect-cgo: not inside a Go module ($MODDIR)" >&2; exit 1; }

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
go list -deps -json "${PATTERNS[@]}" > "$tmp"

mapfile -t CGO_PKGS < <(jq -r 'select((.CgoFiles // []) | length > 0) | select(.Standard != true) | .ImportPath' "$tmp" | sort -u)

if [ "${#CGO_PKGS[@]}" -eq 0 ]; then
  echo "detect-cgo: no third-party cgo dependency found in ${PATTERNS[*]} for $MODULE."
  exit 0
fi

echo "=============================================================="
echo " cgo dependencies found in $MODULE (${PATTERNS[*]})"
echo "=============================================================="
for pkg in "${CGO_PKGS[@]}"; do
  echo
  echo "  $pkg"
  echo "  pulled in by:"
  jq -r --arg p "$pkg" --arg m "$MODULE" '
    select(.Deps != null and (.Deps | index($p) != null) and (.ImportPath | startswith($m)))
    | "    - " + .ImportPath' "$tmp" | sort -u
done
cat <<'EOF'

Why this matters before you fuzz (or ship) it:
  - Go's own fuzzer only instruments the Go side. Coverage-guided fuzzing is
    blind across the cgo boundary -- go test -fuzz cannot see what happens
    inside the C code, so it won't find the memory-safety bugs that live
    there, only reach them by accident.
  - A crash inside C is not a Go panic. recover() does not catch a segfault
    in cgo; it can take the whole process down mid-run, or corrupt memory in
    ways that make a real finding look like a flaky/transient one.
  - CGO_ENABLED=1 needs a matching C toolchain for every target you build
    for, which complicates cross-compilation and air-gapped/reproducible
    builds -- ask whether the dependency is load-bearing before you accept
    that cost.
  - The C library's own memory-safety history becomes yours, usually without
    the same tracking your Go deps get (govulncheck, the Go vuln DB).

If you can't remove it: any fuzz target that reaches one of the packages
above should run isolated (one process per input, so a C-side crash can't
take the whole fuzz run or its corpus with it) rather than fuzzed the normal
way -- corobix does not yet default to this automatically.
EOF
