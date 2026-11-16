#!/usr/bin/env bash
# crasher-pull.sh — Mac-side puller: move new crashers off the vCD fuzz hosts into a
# local quarantine, verified by content hash, and only then delete the host copy.
#
# Why (2026-11-16): the vCD fuzz hosts are provider infrastructure we do not fully
# control; treat them as already compromised. A crasher in a third-party library is an
# undisclosed vulnerability and must not sit on that host until someone pulls it by hand.
#
# One run = one pass. For each host in the FIXED list (CP_HOSTS_FILE, shipped in the
# repo) it lists ~/lane/crashers/<target>/<hash>/ and, per crasher:
#   1. hash    content hash of the dir on the host (manifest of per-file sha256)
#   2. copy    rsync over ssh into $CP_QUARANTINE/.incoming/<host>/<target>/<hash>
#   3. verify  the same hash computed on the Mac must equal the host's; else drop the copy
#   4. keep    mv into $CP_QUARANTINE/<host>/<target>/<hash>, one ledger line, and the
#              marker file for third-party targets ("do not publish")
#   5. delete  a SEPARATE ssh command that re-verifies the host hash and then rm -rf's it
# Any failure leaves the host copy in place. Idempotent: a second pass finds nothing new.
#
# Trust: the host is untrusted (names it lists are validated before use as a path) and so
# is every trigger. This script takes NO arguments naming a host, path or command: only
# --dry-run. Hosts and layout come from the shipped config and constants below.
#
# --dry-run  list what a pass would pull; changes nothing (no copy, no ledger, no delete,
#            no state dir). Read-only ssh commands only.
# Exit: 0 everything pulled (or nothing to do), 1 some crasher stays on a host, 64 usage.
# SC2016: the single-quoted '$1'/'$HOME' strings are scripts for the REMOTE (or sub-) shell on purpose.
# SC2015: "A && B || C" below is "if A and B fail, report and return", intended.
# shellcheck disable=SC2016,SC2015
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP_HOSTS_FILE=${CP_HOSTS_FILE:-$SELF_DIR/deploy/mac/crasher-pull.hosts}
CP_THIRD_PARTY_FILE=${CP_THIRD_PARTY_FILE:-$SELF_DIR/deploy/mac/crasher-pull.third-party}
CP_STATE=${CP_STATE:-$HOME/.crasher-pull}
CP_QUARANTINE=${CP_QUARANTINE:-$HOME/crasher-quarantine}   # keep OUTSIDE any git checkout
CP_LEDGER=${CP_LEDGER:-$CP_STATE/ledger.tsv}
CP_SSH=${CP_SSH:-ssh}
CP_RSYNC=${CP_RSYNC:-rsync}
CP_MAX_PER_PASS=${CP_MAX_PER_PASS:-200}    # a host listing more than this is not a fuzz lane

# Fixed host-side layout. Never built from input.
REMOTE_ROOT_REL='lane/crashers'
LIST_CMD='[ -d "$HOME/lane/crashers" ] || exit 0; cd "$HOME/lane/crashers" && find . -mindepth 2 -maxdepth 2 -type d | sed "s|^\./||"'   # no dir yet = nothing to pull, not an error

DRY=0
plog() { echo "[$(date -u +%FT%TZ)] crasher-pull: $*" >&2; }

# manifest <dir>: sha256 of "<sha256>  <relpath>" lines, sorted. Refuses (exit 3-5) when
# the dir is missing, holds anything but regular files and dirs, or a newline in a name.
# Runs identically on the host (sh over ssh stdin) and on the Mac (sh -s locally).
read -r -d '' MANIFEST_FN <<'EOF'
manifest() {
  ( cd "$1" || exit 3
    [ -z "$(find . ! -type f ! -type d -print -quit)" ] || exit 4
    [ -z "$(find . -name "$(printf '*\n*')" -print -quit)" ] || exit 5
    if command -v sha256sum >/dev/null 2>&1; then H=sha256sum; else H="shasum -a 256"; fi
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do $H "$f"; done | $H | cut -d' ' -f1 )
}
EOF

# One ssh to a host: ssh_to <dest> <jump> <remote command words...>   (stdin passes through)
ssh_to() {
  local dest="$1" jump="$2"; shift 2
  local -a o=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
  [ "$jump" = "-" ] || o+=(-J "$jump")
  "$CP_SSH" "${o[@]}" "$dest" "$@"
}

host_manifest() { # <dest> <jump> <target> <hash>
  printf '%s\nmanifest "$1"\n' "$MANIFEST_FN" |
    ssh_to "$1" "$2" sh -s -- "\$HOME/$REMOTE_ROOT_REL/$3/$4"
}
local_manifest() { printf '%s\nmanifest "$1"\n' "$MANIFEST_FN" | sh -s -- "$1"; }

# host_delete <dest> <jump> <target> <hash> <expected-manifest>: re-verifies ON THE HOST
# that the dir still hashes to what we pulled, then removes it. A separate ssh command.
host_delete() {
  printf '%s\nh=$(manifest "$1") || exit 6\n[ "$h" = "$2" ] || exit 7\ncd / && rm -rf -- "$1"\n' "$MANIFEST_FN" |
    ssh_to "$1" "$2" sh -s -- "\$HOME/$REMOTE_ROOT_REL/$3/$4" "$5"
}

copy_from_host() { # <dest> <jump> <target> <hash> <stage>
  local dest="$1" jump="$2" e="$CP_SSH -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes"
  [ "$jump" = "-" ] || e="$e -J $jump"
  # minimal flags: macOS ships openrsync (2.6.9-compatible). No -l/-p/-o/-g: symlinks are
  # skipped, owner/mode are not taken from the host; umask 077 keeps the copy private.
  "$CP_RSYNC" -rt --timeout=300 -e "$e" -- "$dest:$REMOTE_ROOT_REL/$3/$4/" "$5/"
}

is_third_party() { # <target>
  [ -f "$CP_THIRD_PARTY_FILE" ] && grep -v '^[[:space:]]*#' "$CP_THIRD_PARTY_FILE" | grep -qxF -- "$1"
}

ledger() { # <host> <target> <hash> <status> <third-party|->
  mkdir -p "$(dirname "$CP_LEDGER")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" "$5" >> "$CP_LEDGER"
}
ledger_has() { [ -f "$CP_LEDGER" ] && awk -F'\t' -v h="$1" -v t="$2" -v x="$3" -v s="$4" \
  '$2==h && $3==t && $4==x && $5==s {f=1} END{exit !f}' "$CP_LEDGER"; }

# process_crasher <host> <dest> <jump> <target> <hash> -> 0 pulled+deleted (or dry), 1 stays on host
process_crasher() {
  local host="$1" dest="$2" jump="$3" target="$4" hash="$5"
  local final="$CP_QUARANTINE/$host/$target/$hash" stage="$CP_QUARANTINE/.incoming/$host/$target/$hash"
  local want got tp="-" have=""
  want=$(host_manifest "$dest" "$jump" "$target" "$hash") || { plog "$host $target/$hash: cannot hash on host (special file, unreadable?) — stays on host"; return 1; }
  [ -n "$want" ] || { plog "$host $target/$hash: empty host hash — stays on host"; return 1; }
  is_third_party "$target" && tp="third-party"
  if [ -d "$final" ]; then
    have=$(local_manifest "$final")
    if [ "$have" != "$want" ]; then
      plog "$host $target/$hash: CONFLICT — quarantine copy differs from host copy; host copy stays, nothing overwritten"
      return 1
    fi
  fi
  if [ "$DRY" = 1 ]; then # GUARD:dry-run
    plog "DRY-RUN $host $target/$hash: would $([ -n "$have" ] && echo 'delete host copy (already in quarantine)' || echo 'pull, verify, then delete host copy') [$tp] hash=${want:0:12}"
    return 0
  fi
  if [ -z "$have" ]; then
    rm -rf "$stage"; mkdir -p "$stage" || return 1
    if ! copy_from_host "$dest" "$jump" "$target" "$hash" "$stage" < /dev/null; then # GUARD:copy-ok
      plog "$host $target/$hash: copy failed or interrupted — host copy stays"
      rm -rf "$stage"; return 1
    fi
    got=$(local_manifest "$stage") || got=""
    if [ -z "$got" ] || [ "$got" != "$want" ]; then # GUARD:hash-verify
      plog "$host $target/$hash: HASH MISMATCH after copy (host ${want:0:12} vs local ${got:0:12}) — host copy stays"
      rm -rf "$stage"; return 1
    fi
    mkdir -p "$CP_QUARANTINE/$host/$target" && mv "$stage" "$final" || { plog "$host $target/$hash: cannot move into quarantine — host copy stays"; return 1; }
    [ "$tp" = "-" ] || echo "third-party: do not publish" > "$CP_QUARANTINE/$host/$target/$hash.DO-NOT-PUBLISH"
    ledger "$host" "$target" "$hash" pulled-ok "$tp"
    plog "$host $target/$hash: pulled and verified (hash ${want:0:12}) [$tp]"
  elif ! ledger_has "$host" "$target" "$hash" pulled-ok; then
    [ "$tp" = "-" ] || echo "third-party: do not publish" > "$CP_QUARANTINE/$host/$target/$hash.DO-NOT-PUBLISH"
    ledger "$host" "$target" "$hash" pulled-ok "$tp"
  fi
  if host_delete "$dest" "$jump" "$target" "$hash" "$want"; then
    ledger "$host" "$target" "$hash" host-deleted "$tp"
    plog "$host $target/$hash: host copy deleted"
    return 0
  fi
  plog "$host $target/$hash: pulled OK but host delete failed or hash changed on host — host copy stays, next pass retries"
  return 1
}

pass_host() { # <host> <dest> <jump> -> sets PULLED/FAILED counters
  local host="$1" dest="$2" jump="$3" listing line target hash n=0
  if ! listing=$(ssh_to "$dest" "$jump" "$LIST_CMD" < /dev/null); then
    # find exits non-zero only on a host that cannot be reached (an absent dir yields no output, rc 0)
    plog "$host: ssh failed — skipped this pass"; FAILED=$((FAILED+1)); return
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    target=${line%%/*}; hash=${line#*/}
    # the host is untrusted: only plain names ever become a path component or part of a command
    if ! [[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || ! [[ "$hash" =~ ^[0-9a-f]{8,64}$ ]]; then # GUARD:name-validate
      plog "$host: ignoring unsafe or unexpected entry (not a <target>/<hex hash> pair)"
      FAILED=$((FAILED+1)); continue
    fi
    n=$((n+1))
    if [ "$n" -gt "$CP_MAX_PER_PASS" ]; then plog "$host: more than $CP_MAX_PER_PASS crashers listed — stopping this host"; FAILED=$((FAILED+1)); break; fi
    if process_crasher "$host" "$dest" "$jump" "$target" "$hash"; then PULLED=$((PULLED+1)); else FAILED=$((FAILED+1)); fi
  done <<< "$listing"
}

main() {
  case "${1:-}" in
    --dry-run) DRY=1 ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]   (hosts come from $CP_HOSTS_FILE only)" >&2; return 64 ;;
  esac
  [ $# -le 1 ] || { echo "usage: $0 [--dry-run]" >&2; return 64; }
  [ -f "$CP_HOSTS_FILE" ] || { plog "no hosts file at $CP_HOSTS_FILE"; return 1; }
  umask 077
  if [ "$DRY" = 0 ]; then
    mkdir -p "$CP_STATE" "$CP_QUARANTINE" || return 1
    # one pass at a time (mkdir is atomic; a dead holder's lock is stale)
    if ! mkdir "$CP_STATE/lock" 2>/dev/null; then
      if kill -0 "$(cat "$CP_STATE/lock/pid" 2>/dev/null)" 2>/dev/null; then plog "another pass is running — skip"; return 0; fi
      rm -rf "$CP_STATE/lock"; mkdir "$CP_STATE/lock" || return 1
    fi
    echo $$ > "$CP_STATE/lock/pid"
    trap 'rm -rf "$CP_STATE/lock"' EXIT
  fi
  PULLED=0; FAILED=0
  plog "pass start$([ "$DRY" = 1 ] && echo ' (dry-run: nothing is changed)')"
  local name dest jump nh=0
  while read -r name dest jump _ <&3; do   # fd 3: ssh/rsync below must not eat the hosts file
    case "$name" in ''|'#'*) continue ;; esac
    jump=${jump:--}
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || ! [[ "$dest" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] \
       || { [ "$jump" != "-" ] && ! [[ "$jump" =~ ^[A-Za-z0-9][A-Za-z0-9._@,:-]*$ ]]; }; then
      plog "bad line in hosts file (name/dest/jump): skipped"; FAILED=$((FAILED+1)); continue
    fi
    nh=$((nh+1)); pass_host "$name" "$dest" "$jump"
  done 3< "$CP_HOSTS_FILE"
  plog "pass done: hosts=$nh crashers_handled=$PULLED left_or_failed=$FAILED"
  [ "$FAILED" -eq 0 ]
}

main "$@"
