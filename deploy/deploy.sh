#!/usr/bin/env bash
# deploy.sh — one-command, git-stamped, verified deploy of THIS checkout's
# fuzz-runner.sh to a fuzz rig (or all of them).
#
# WHY push-from-here and not git-pull-on-the-rig: fuzz-harness is private, and
# the rigs only hold a deploy key scoped to the corpus repo — giving each rig a
# fuzz-harness read credential is more attack surface for no real gain. This runs
# from a checkout that already has repo access (your dev box), pushes the runner
# over ssh, and stamps the exact commit on the rig (DEPLOYED_FROM.txt) so what is
# running is always auditable. Human-gated: you run it, deliberately, per change.
#
# It does NOT touch systemd (the andrei rigs need a sudo password for that). The
# runner reloads itself on a config-hash change (exec "$0"), so after the new
# binary is in place we bump a marker line in the rig-local fuzz.conf to trigger
# that reload — no root required.
#
# Usage:
#   deploy/deploy.sh <rig>...                 keyorix | dashdiag | libs-extra | libs
#   deploy/deploy.sh --all
#   deploy/deploy.sh --list
#   DEPLOY_SKIP_GATE=1 deploy/deploy.sh ...    skip the shellcheck+bats gate (not advised)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

RIGS_KEYS=(keyorix dashdiag libs-extra libs)
rig_spec() {   # rig -> "ssh_host|runner_dir|conf_path"
  case "$1" in
    keyorix)    echo "vcd-keyorix-fuzz|/home/andrei/proj/fuzz-harness|/home/andrei/proj/fuzz-harness/fuzz.conf" ;;
    dashdiag)   echo "vcd-dashdiag-fuzz|/home/andrei/proj/fuzz-harness|/home/andrei/proj/fuzz-harness/fuzz.conf" ;;
    libs-extra) echo "vcd-dashdiag-fuzz|/home/andrei/proj/libs-extra-fuzz|/home/andrei/proj/libs-extra-fuzz/fuzz.conf" ;;
    libs)       echo "pve01|/root/libs-fuzz|/root/libs-fuzz/fuzz.conf" ;;
    *) return 1 ;;
  esac
}

die() { echo "deploy: $*" >&2; exit 1; }

gate() {
  [ "${DEPLOY_SKIP_GATE:-0}" = 1 ] && { echo "deploy: gate SKIPPED (DEPLOY_SKIP_GATE=1)"; return 0; }
  echo "deploy: gate — shellcheck + bats"
  command -v shellcheck >/dev/null || die "shellcheck not found (install it, or DEPLOY_SKIP_GATE=1)"
  shellcheck fuzz-runner.sh || die "shellcheck failed — refusing to deploy"
  if command -v bats >/dev/null && [ -f tests/runner.bats ]; then
    bats tests/runner.bats >/dev/null || die "bats runner tests failed — refusing to deploy"
  else
    echo "deploy: (bats or tests/runner.bats missing — skipping test leg of gate)"
  fi
  echo "deploy: gate OK"
}

# Identity of what we are shipping (computed once).
GIT_SHA="$(git rev-parse HEAD)"
GIT_DESC="$(git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"
RUNNER_SHA="$(shasum -a 256 fuzz-runner.sh | cut -d' ' -f1)"
DEPLOYER="$(whoami)@$(hostname -s)"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

deploy_one() {
  local rig="$1" spec host dir conf
  spec="$(rig_spec "$rig")" || die "unknown rig '$rig' (see --list)"
  IFS='|' read -r host dir conf <<<"$spec"
  echo "==> $rig ($host:$dir)"

  ssh "$host" mkdir -p "$dir" || die "[$rig] mkdir $dir failed"

  # Seed fuzz.conf from the checked-in template when the rig has none yet. Never
  # overwrites an existing one -- fuzz.conf is box-local/gitignored by design
  # (targets/README.md), so nothing else ever creates it, and a config fix (e.g.
  # lifting an EXCLUDE) only reaches a rig this way on first deploy or a rebuild.
  # shellcheck disable=SC2029  # intentional: $conf is THIS script's known value,
  # not something the remote shell should resolve independently.
  if ! ssh "$host" "[ -f '$conf' ]"; then
    [ -f "examples/$rig.conf" ] || die "[$rig] rig has no fuzz.conf and there is no examples/$rig.conf to seed it from"
    scp -q "examples/$rig.conf" "$host:$conf" || die "[$rig] scp fuzz.conf template failed"
    echo "    seeded $conf from examples/$rig.conf (rig had none)"
  fi

  scp -q fuzz-runner.sh "$host:$dir/.fuzz-runner.sh.new" || die "[$rig] scp failed"

  # Advisory-only helper the runner shells out to at startup if present (see
  # fuzz-runner.sh's drift-guard call) — not sha-verified like the runner itself,
  # since a stale/missing copy only means one warning line is skipped, never a
  # wrong fuzz result.
  ssh "$host" mkdir -p "$dir/scripts" || die "[$rig] mkdir scripts failed"
  scp -q scripts/check-shared-pins.sh scripts/pin-drift-allowlist.tsv "$host:$dir/scripts/" || die "[$rig] scp drift-guard failed"

  # Quoted heredoc: NO local expansion. All values are passed as positional args
  # (each a single space-free token: paths, hex shas, a tag, user@host, an ISO ts),
  # so ssh's arg-joining is safe and the remote does all the work.
  ssh "$host" bash -s -- \
      "$dir" "$RUNNER_SHA" "$conf" "$GIT_SHA" "$GIT_DESC" "$DEPLOYER" "$DEPLOYED_AT" <<'EOF' || die "[$rig] remote install failed"
set -euo pipefail
dir="$1"; want_sha="$2"; conf="$3"; git_sha="$4"; git_desc="$5"; deployer="$6"; at="$7"
got="$(sha256sum "$dir/.fuzz-runner.sh.new" | cut -d' ' -f1)"
[ "$got" = "$want_sha" ] || { echo "sha mismatch: want $want_sha got $got" >&2; rm -f "$dir/.fuzz-runner.sh.new"; exit 1; }
chmod +x "$dir/.fuzz-runner.sh.new"
mv -f "$dir/.fuzz-runner.sh.new" "$dir/fuzz-runner.sh"
printf 'runner=fuzz-runner.sh\ngit_sha=%s\ngit_describe=%s\nsha256=%s\ndeployed_at=%s\ndeployed_by=%s\n' \
  "$git_sha" "$git_desc" "$want_sha" "$at" "$deployer" > "$dir/DEPLOYED_FROM.txt"
# Bump a marker line in fuzz.conf to change its hash and trip the runner's
# config-hash reload (exec "$0"), which picks up the new binary. No root needed.
if [ -w "$conf" ]; then
  grep -v '^# _deployed_runner:' "$conf" > "$conf.tmp" 2>/dev/null || true
  printf '# _deployed_runner: %s %s\n' "$git_desc" "$at" >> "$conf.tmp"
  mv -f "$conf.tmp" "$conf"
  echo "reload triggered via $conf"
else
  echo "WARN: $conf not writable — runner will reload on its next config change" >&2
fi
echo "installed sha256=$(sha256sum "$dir/fuzz-runner.sh" | cut -d' ' -f1)"
EOF
  echo "    stamped $GIT_DESC ($RUNNER_SHA)"
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  [ "$#" -ge 1 ] || { usage; exit 1; }
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) printf '%s\n' "${RIGS_KEYS[@]}"; exit 0 ;;
  esac

  local targets=()
  if [ "$1" = "--all" ]; then targets=("${RIGS_KEYS[@]}"); else targets=("$@"); fi
  local r
  for r in "${targets[@]}"; do rig_spec "$r" >/dev/null || die "unknown rig '$r' (valid: ${RIGS_KEYS[*]})"; done

  gate
  echo "deploy: shipping $GIT_DESC ($RUNNER_SHA) to: ${targets[*]}"
  for r in "${targets[@]}"; do deploy_one "$r"; done
  echo "deploy: done — ${#targets[@]} rig(s). Audit: ssh <host> cat <dir>/DEPLOYED_FROM.txt"
}

main "$@"
