#!/usr/bin/env bash
# Local pre-PR gate for fuzz-harness. Hosted CI is intentionally disabled for this
# repo (the .github/workflows/ci.yml workflow was removed) — run this before every
# PR. Mirrors what CI ran (shellcheck + bats) and adds go vet + govulncheck on the
# target modules.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== shellcheck =="
shellcheck fuzz-runner.sh harvest-crashers.sh scripts/require-deadline.sh scripts/check-shared-pins.sh

echo "== bats =="
bats tests/

echo "== go vet (target modules) =="
for m in targets/*/; do
	[ -f "${m}go.mod" ] || continue
	echo "  ${m}"
	( cd "$m" && go vet ./... )
done

# Version matches keyorix's own ci.yml pin (golang.org/x/vuln/cmd/govulncheck@v1.8.0) --
# not enforced here, just kept in sync by convention so a finding means the same thing
# in both places. Not auto-installed (same as shellcheck/bats above): install once with
# `go install golang.org/x/vuln/cmd/govulncheck@v1.8.0`.
echo "== govulncheck (target modules) =="
for m in targets/*/; do
	[ -f "${m}go.mod" ] || continue
	echo "  ${m}"
	( cd "$m" && govulncheck ./... )
done

echo "== require-deadline lint (per-input deadline on every target) =="
scripts/require-deadline.sh

echo "== shared-module pin drift (targets/*/go.mod vs keyorix main) =="
scripts/check-shared-pins.sh

echo "OK - all local checks passed"
