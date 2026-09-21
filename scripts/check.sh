#!/usr/bin/env bash
# Local pre-PR gate for fuzz-harness. Hosted CI is intentionally disabled for this
# repo (the .github/workflows/ci.yml workflow was removed) — run this before every
# PR. Mirrors what CI ran (shellcheck + bats) and adds go vet on the target modules.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== shellcheck =="
shellcheck fuzz-runner.sh harvest-crashers.sh scripts/require-deadline.sh

echo "== bats =="
bats tests/

echo "== go vet (target modules) =="
for m in targets/*/; do
	[ -f "${m}go.mod" ] || continue
	echo "  ${m}"
	( cd "$m" && go vet ./... )
done

echo "== require-deadline lint (per-input deadline on every target) =="
scripts/require-deadline.sh

echo "OK - all local checks passed"
