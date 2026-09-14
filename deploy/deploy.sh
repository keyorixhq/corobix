#!/usr/bin/env bash
# deploy.sh — one-command, git-stamped, verified operations on a fuzz rig.
#
# Three things this does, each human-gated and auditable:
#   <rig>... | --all         push THIS checkout's fuzz-runner.sh to a running rig
#                            (no root; trips the runner's config-hash self-reload)
#   --unit <rig>...          install/reconcile the rig's canonical systemd unit
#                            from deploy/systemd/<svc>.service (needs sudo on rig)
#   --bootstrap <rig>        cold-start a fresh rig from nothing: dirs, module,
#                            seed conf, runner, unit, enable --now (needs sudo)
#
# WHY push-from-here and not git-pull-on-the-rig: fuzz-harness is private, and
# the rigs only hold a deploy key scoped to the corpus repo — giving each rig a
# fuzz-harness read credential is more attack surface for no real gain. This runs
# from a checkout that already has repo access (your dev box), pushes the runner
# over ssh, and stamps the exact commit on the rig (DEPLOYED_FROM.txt) so what is
# running is always auditable. Human-gated: you run it, deliberately, per change.
#
# The plain runner push does NOT touch systemd (the andrei rigs need a sudo
# password for that). The runner reloads itself on a config-hash change
# (exec "$0"), so after the new binary is in place we bump a marker line in the
# rig-local fuzz.conf to trigger that reload — no root required. --unit and
# --bootstrap DO touch systemd and therefore need sudo on the rig.
#
# Preview any of it without touching a rig:  --dry-run  prints the exact plan.
#
# Usage:
#   deploy/deploy.sh <rig>...                  keyorix | dashdiag | libs-extra | libs
#   deploy/deploy.sh --all
#   deploy/deploy.sh --unit <rig>...           reconcile the systemd unit(s)
#   deploy/deploy.sh --bootstrap <rig>         cold-start a fresh rig
#   deploy/deploy.sh --dry-run <any of the above>
#   deploy/deploy.sh --list
#   DEPLOY_SKIP_GATE=1 deploy/deploy.sh ...     skip the shellcheck+bats gate (not advised)
set -euo pipefail

# ── rig registry ─────────────────────────────────────────────────────────────
# One record per rig, the single place rig facts live:
#   host | runner_path | conf | service | source_mode | module_dir | module_repo | seed_conf
# runner_path is the unit's ExecStart (where the SERVICE runs the runner from) —
# for libs-extra that is the copy SHARED with dashdiag on the same box, not a
# private copy. conf is what that service's runner reads ($FUZZ_CONF or the
# fuzz.conf beside the runner). module_repo/seed_conf are '-' when N/A.
RIGS_KEYS=(keyorix dashdiag libs-extra libs)
rig_rec() {
  case "$1" in
    keyorix)    echo "vcd-keyorix-fuzz|/home/andrei/proj/fuzz-harness/fuzz-runner.sh|/home/andrei/proj/fuzz-harness/fuzz.conf|keyorix-fuzz|git|/opt/keyorix-fuzz/keyorix|https://github.com/keyorixhq/keyorix.git|examples/keyorix.conf" ;;
    dashdiag)   echo "vcd-dashdiag-fuzz|/home/andrei/proj/fuzz-harness/fuzz-runner.sh|/home/andrei/proj/fuzz-harness/fuzz.conf|dashdiag-fuzz|git|/home/andrei/proj/dashdiag|https://github.com/keyorixhq/dashdiag.git|examples/dashdiag.conf" ;;
    libs-extra) echo "vcd-dashdiag-fuzz|/home/andrei/proj/fuzz-harness/fuzz-runner.sh|/home/andrei/proj/libs-extra-fuzz/fuzz.conf|libs-extra-fuzz|standalone|/home/andrei/proj/libs-extra-fuzz|-|-" ;;
    libs)       echo "pve01|/root/libs-fuzz/fuzz-runner.sh|/root/libs-fuzz/fuzz.conf|libsfuzz|standalone|/root/libs-fuzz|-|examples/libs.conf" ;;
    *) return 1 ;;
  esac
}
# Field extractor: rig_field <rig> <1-based index into the pipe record>.
rig_field() { rig_rec "$1" | cut -d'|' -f"$2"; }

die() { echo "deploy: $*" >&2; exit 1; }

# ── the sourcing guard: bats sources this file to test the pure helpers above
# (rig_rec/rig_field/plan builders) without running main(). Mirrors the runner's
# FUZZ_RUNNER_LIB pattern.
[ -n "${DEPLOY_LIB:-}" ] && return 0 2>/dev/null   # test hook: source for functions only

cd "$(dirname "$0")/.."   # repo root (after the lib-guard so sourcing is side-effect-free)

DRY_RUN="${DRY_RUN:-0}"

gate() {
  [ "$DRY_RUN" = 1 ] && { echo "deploy: gate skipped (dry-run makes no changes)"; return 0; }
  [ "${DEPLOY_SKIP_GATE:-0}" = 1 ] && { echo "deploy: gate SKIPPED (DEPLOY_SKIP_GATE=1)"; return 0; }
  echo "deploy: gate — shellcheck + bats"
  command -v shellcheck >/dev/null || die "shellcheck not found (install it, or DEPLOY_SKIP_GATE=1)"
  shellcheck fuzz-runner.sh deploy/deploy.sh || die "shellcheck failed — refusing to deploy"
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

# say — print a plan/step line (indented).
say() { printf '    %s\n' "$*"; }

# ── plain runner push (no root) ──────────────────────────────────────────────
deploy_one() {
  local rig="$1" host runner_path conf dir
  host="$(rig_field "$rig" 1)"; runner_path="$(rig_field "$rig" 2)"; conf="$(rig_field "$rig" 3)"
  dir="$(dirname "$runner_path")"
  echo "==> $rig ($host:$dir)"
  if [ "$DRY_RUN" = 1 ]; then
    say "scp fuzz-runner.sh -> $host:$dir/fuzz-runner.sh  (sha $RUNNER_SHA)"
    say "stamp DEPLOYED_FROM.txt ($GIT_DESC) and bump reload marker in $conf"
    return 0
  fi
  scp -q fuzz-runner.sh "$host:$dir/.fuzz-runner.sh.new" || die "[$rig] scp failed"
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

# ── systemd unit install / reconcile (needs sudo on the rig) ─────────────────
# Installs deploy/systemd/<svc>.service verbatim (the tracked, canonical unit),
# daemon-reload, restart, verify. Does NOT remove unknown drop-ins — it warns if
# any exist so you can decide (the one-time migration drop-in removal is in the
# README runbook, not automated here).
install_unit() {
  local rig="$1" host service unit
  host="$(rig_field "$rig" 1)"; service="$(rig_field "$rig" 4)"
  unit="deploy/systemd/$service.service"
  [ -f "$unit" ] || die "[$rig] canonical unit $unit not found"
  echo "==> unit $rig ($host: $service.service)"
  if [ "$DRY_RUN" = 1 ]; then
    say "scp $unit -> $host:/tmp/$service.service"
    say "ssh $host sudo: install -m0644 -> /etc/systemd/system/$service.service"
    say "ssh $host sudo: warn if drop-ins under $service.service.d exist; daemon-reload; restart $service; verify is-active"
    return 0
  fi
  scp -q "$unit" "$host:/tmp/$service.service" || die "[$rig] unit scp failed"
  ssh -t "$host" sudo bash -s -- "$service" <<'EOF' || die "[$rig] unit install failed"
set -euo pipefail
svc="$1"; ts="$(date +%s)"
cp -a "/etc/systemd/system/$svc.service" "/root/$svc.service.bak.$ts" 2>/dev/null || true
install -m0644 "/tmp/$svc.service" "/etc/systemd/system/$svc.service"
rm -f "/tmp/$svc.service"
if [ -d "/etc/systemd/system/$svc.service.d" ]; then
  echo "NOTE: drop-ins still present under $svc.service.d (left in place):"
  ls -1 "/etc/systemd/system/$svc.service.d" || true
  echo "  Remove them by hand if they were meant to be folded into the unit (see README)."
fi
systemctl daemon-reload
systemctl restart "$svc"
sleep 5
systemctl is-active "$svc"
systemctl show "$svc" -p ExecStart -p MemoryMax -p MemorySwapMax --value
EOF
  echo "    installed $service.service (backup on rig at /root/$service.service.bak.*)"
}

# ── cold-start bootstrap of a fresh rig (needs sudo on the rig) ──────────────
bootstrap_one() {
  local rig="$1" host runner_path conf service smode mdir mrepo seed dir
  host="$(rig_field "$rig" 1)"; runner_path="$(rig_field "$rig" 2)"; conf="$(rig_field "$rig" 3)"
  service="$(rig_field "$rig" 4)"; smode="$(rig_field "$rig" 5)"; mdir="$(rig_field "$rig" 6)"
  mrepo="$(rig_field "$rig" 7)"; seed="$(rig_field "$rig" 8)"
  dir="$(dirname "$runner_path")"
  echo "==> bootstrap $rig ($host)  runner=$dir  module=$mdir ($smode)"

  # 1. module tree
  if [ "$smode" = git ] && [ "$mrepo" != - ]; then
    say "module: git clone $mrepo -> $mdir (skip if present; sudo if under /opt or /root)"
  else
    say "module: STANDALONE — assemble the tree at $mdir by hand (nothing to clone)"
  fi
  # 2. dirs
  say "mkdir -p $dir  and the state/log/findings dirs named in the conf"
  # 3. seed conf (never clobber an existing one)
  local confdir; confdir="$(dirname "$conf")"
  if [ "$seed" != - ] && [ -f "$seed" ]; then
    say "seed conf: scp $seed -> $host:$conf  (ONLY if $conf absent; edit paths/REPORT_MODE after)"
  else
    say "seed conf: none tracked — author $confdir/$(basename "$conf") by hand (see examples/)"
  fi
  # 4. runner
  say "runner: push fuzz-runner.sh -> $dir/fuzz-runner.sh ($GIT_DESC)"
  # 5. unit + enable
  say "unit: install deploy/systemd/$service.service (sudo), daemon-reload, enable --now $service"

  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] no changes made. Re-run without --dry-run on a prepared rig."
    return 0
  fi

  # Preconditions that are cheap to check and dangerous to skip.
  ssh "$host" "command -v go >/dev/null && command -v git >/dev/null" \
    || die "[$rig] rig is missing go and/or git on PATH — install the toolchain first"
  # shellcheck disable=SC2029  # values are printf %q-quoted for the remote shell — client-side expansion is intended
  ssh "$host" "mkdir -p $(printf %q "$dir") $(printf %q "$confdir")" || die "[$rig] mkdir failed"

  if [ "$smode" = git ] && [ "$mrepo" != - ]; then
    # shellcheck disable=SC2029  # values are printf %q-quoted for the remote shell — client-side expansion is intended
    ssh "$host" "test -d $(printf %q "$mdir")/.git || { echo 'cloning module (sudo if needed)'; sudo -n mkdir -p $(printf %q "$mdir") 2>/dev/null || mkdir -p $(printf %q "$mdir"); git clone $(printf %q "$mrepo") $(printf %q "$mdir"); }" \
      || die "[$rig] module clone failed (clone it by hand into $mdir, then re-run)"
  else
    # shellcheck disable=SC2029  # values are printf %q-quoted for the remote shell — client-side expansion is intended
    ssh "$host" "test -e $(printf %q "$mdir")" \
      || die "[$rig] standalone module dir $mdir absent — assemble the tree first, then re-run"
  fi

  if [ "$seed" != - ] && [ -f "$seed" ]; then
    # shellcheck disable=SC2029  # printf %q-quoted; client-side expansion intended
    if ssh "$host" "test -f $(printf %q "$conf")"; then
      say "conf already present at $conf — left untouched"
    else
      scp -q "$seed" "$host:$conf" || die "[$rig] conf seed scp failed"
      say "seeded $conf from $seed — EDIT it (paths, REPORT_MODE, durations) before it matters"
    fi
  fi

  deploy_one "$rig"
  install_unit "$rig"
  # shellcheck disable=SC2029  # values are printf %q-quoted for the remote shell — client-side expansion is intended
  ssh -t "$host" "sudo systemctl enable --now $(printf %q "$service")" || die "[$rig] enable --now failed"
  echo "    bootstrapped $rig — verify: ssh $host systemctl is-active $service; tail its rotation log"
}

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  [ "$#" -ge 1 ] || { usage; exit 1; }

  # optional leading --dry-run
  if [ "$1" = "--dry-run" ]; then DRY_RUN=1; shift; [ "$#" -ge 1 ] || die "--dry-run needs an action"; fi

  local mode=deploy
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) printf '%s\n' "${RIGS_KEYS[@]}"; exit 0 ;;
    --unit) mode=unit; shift ;;
    --bootstrap) mode=bootstrap; shift ;;
  esac
  [ "$#" -ge 1 ] || die "no rig(s) given (see --list)"

  # Build + validate the target list in main's own shell (NOT a subshell) so a
  # bad rig's die() aborts the command instead of just a subshell.
  local targets=() r
  if [ "$1" = "--all" ]; then targets=("${RIGS_KEYS[@]}"); else targets=("$@"); fi
  for r in "${targets[@]}"; do rig_rec "$r" >/dev/null || die "unknown rig '$r' (valid: ${RIGS_KEYS[*]})"; done

  local dry_label=""; [ "$DRY_RUN" = 1 ] && dry_label=" (dry-run)"

  case "$mode" in
    deploy)
      gate
      echo "deploy: shipping $GIT_DESC ($RUNNER_SHA) to: ${targets[*]}$dry_label"
      local r; for r in "${targets[@]}"; do deploy_one "$r"; done
      echo "deploy: done — ${#targets[@]} rig(s). Audit: ssh <host> cat <dir>/DEPLOYED_FROM.txt" ;;
    unit)
      echo "deploy: installing canonical unit(s) to: ${targets[*]}$dry_label"
      local r; for r in "${targets[@]}"; do install_unit "$r"; done
      echo "deploy: unit(s) done — ${#targets[@]} rig(s)." ;;
    bootstrap)
      [ "${#targets[@]}" -eq 1 ] || die "--bootstrap takes exactly one rig at a time"
      gate
      echo "deploy: bootstrapping ${targets[0]}$dry_label"
      bootstrap_one "${targets[0]}" ;;
  esac
}

main "$@"
