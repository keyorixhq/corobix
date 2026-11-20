#!/usr/bin/env bash
# weekly-pin-sync.sh — run by launchd (deploy/mac/com.keyorix.corobix-pin-sync.plist),
# weekly. Brings targets/*/go.mod back in line with keyorix main, verified
# (scripts/sync-shared-pins.sh: tidy, vet, seed tests, rollback on failure),
# and opens ONE pull request with the result. Nothing is deployed and nothing is
# merged: a human merges, then runs deploy/deploy.sh libs-extra.
#
# Usage: scripts/weekly-pin-sync.sh [REPO_DIR]   (default ~/proj/corobix)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
REPO="${1:-$HOME/proj/corobix}"
BASE="origin/main"
day="$(date -u +%F)"
branch="chore/pin-sync-$day"
log() { echo "[$(date -u +%FT%TZ)] weekly-pin-sync: $*"; }

cd "$REPO"
git fetch -q origin
# one open sync PR at a time — a human has not merged last week's yet
if [ -n "$(gh pr list --state open --search 'head:chore/pin-sync-' --json number --jq '.[].number')" ]; then
	log "an open pin-sync PR already exists — nothing to do"
	exit 0
fi

wt="$(mktemp -d)/pin-sync"
git worktree add -q -b "$branch" "$wt" "$BASE"
trap 'cd "$REPO"; git worktree remove --force "$wt" 2>/dev/null || true; git branch -D "$branch" >/dev/null 2>&1 || true' EXIT

cd "$wt"
report="$(mktemp)"
rc=0
scripts/sync-shared-pins.sh --apply >"$report" 2>&1 || rc=$?
cat "$report"

if [ -z "$(git status --porcelain targets)" ]; then
	log "no pin changes (rc=$rc)"
	[ "$rc" -eq 0 ] || exit "$rc"
	exit 0
fi

git add targets
git commit -q -s -m "chore(targets): sync shared pins to keyorix main ($day)" \
	-m "Automated weekly sync (scripts/sync-shared-pins.sh). Each bump was verified with go mod tidy, go vet and the seed tests; a target that failed verification was left unchanged." \
	-m "$(grep -E '^(BUMP|SKIP|FAIL)' "$report" | cut -c1-200)"
git -c credential.helper='!gh auth git-credential' push -q https://github.com/keyorixhq/corobix.git "$branch"
gh pr create --base main --head "$branch" \
	--title "chore(targets): sync shared pins to keyorix main ($day)" \
	--body "$(printf 'Weekly automated pin sync. After merging, ship it to the rigs: `deploy/deploy.sh libs-extra`.\n\n```\n%s\n```\n' "$(cat "$report")")"
log "PR opened (sync rc=$rc)"
exit "$rc"
