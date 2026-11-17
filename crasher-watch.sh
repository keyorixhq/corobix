#!/usr/bin/env bash
# crasher-watch.sh — triggers for crasher-pull.sh. A trigger means ONE thing: "run a pass
# now". Nothing read from GitHub or ntfy is ever used as a host name, path or command, or
# even passed to the puller: it is always invoked with NO arguments. (The 10-minute launchd
# schedule in deploy/mac/ is the safety net if a trigger is missed or the Mac was asleep.)
#
#   --once    one poll of keyorixhq/fuzz-corpus issues (label vcd-auto); run a pass if an
#             issue is new or has a new comment since the last poll. Conditional request:
#             ETag / If-None-Match, a 304 costs no rate limit and runs nothing.
#   --ntfy    listen on the ntfy topic; every message event runs a pass (speed-up only)
#   --loop    --once every CW_POLL_SECS (default 90) and --ntfy in the background if configured
#
# Files on the Mac, referenced by path only (never in the repo):
#   CW_TOKEN_FILE  GitHub token with issues:read on keyorixhq/fuzz-corpus (default
#                  ~/.config/crasher-pull/issues-token)
#   CW_NTFY_FILE   one line, the https ntfy topic URL (default ~/.config/crasher-pull/ntfy-url)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CW_PULL=${CW_PULL:-$SELF_DIR/crasher-pull.sh}
CW_STATE=${CW_STATE:-$HOME/.crasher-pull/watch}
CW_TOKEN_FILE=${CW_TOKEN_FILE:-$HOME/.config/crasher-pull/issues-token}
CW_NTFY_FILE=${CW_NTFY_FILE:-$HOME/.config/crasher-pull/ntfy-url}
CW_CURL=${CW_CURL:-curl}
CW_POLL_SECS=${CW_POLL_SECS:-90}
CW_MIN_GAP=${CW_MIN_GAP:-20}     # seconds between ntfy-triggered passes
ISSUES_URL='https://api.github.com/repos/keyorixhq/fuzz-corpus/issues?labels=vcd-auto&state=all&sort=updated&direction=desc&per_page=50'

wlog() { echo "[$(date -u +%FT%TZ)] crasher-watch: $*" >&2; }

# run_pass <why>: the only thing a trigger does. No data from the trigger goes in.
run_pass() {
  wlog "trigger ($1): running a pass"
  "$CW_PULL" # GUARD:trigger-no-args
}

sha_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

poll_once() {
  local tok etag="" code hdr body digest old
  mkdir -p "$CW_STATE" || return 1
  [ -r "$CW_TOKEN_FILE" ] || { wlog "no token file at $CW_TOKEN_FILE — issue polling off (the schedule still pulls)"; return 2; }
  tok=$(tr -d '\r\n' < "$CW_TOKEN_FILE")
  [[ "$tok" =~ ^[A-Za-z0-9_]+$ ]] || { wlog "token file content is not a plain token — polling off"; return 2; }
  [ -f "$CW_STATE/etag" ] && etag=$(cat "$CW_STATE/etag")
  hdr="$CW_STATE/last.headers"; body="$CW_STATE/last.body"
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" |
    "$CW_CURL" -sS -m 30 --config - -D "$hdr" -o "$body" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      ${etag:+-H "If-None-Match: $etag"} "$ISSUES_URL") || { wlog "poll failed (network?) — will retry"; return 1; }
  case "$code" in
    304) return 0 ;;
    200) ;;
    *) wlog "poll: unexpected HTTP $code — will retry"; return 1 ;;
  esac
  # digest of "<number> <updated_at> <comments>" per vcd-auto issue: a new issue OR a new
  # comment changes it. Only these three fields are read, and only to be hashed.
  digest=$(jq -r '.[] | select(has("pull_request") | not)
                  | select(any(.labels[]?; .name == "vcd-auto"))
                  | "\(.number) \(.updated_at) \(.comments)"' "$body" 2>/dev/null | sha_stdin) || digest="" # GUARD:comments-count
  [ -n "$digest" ] || { wlog "poll: could not parse the issue list — will retry"; return 1; }
  old=$(cat "$CW_STATE/digest" 2>/dev/null)
  if [ "$digest" != "$old" ]; then
    run_pass "vcd-auto issue activity" || { wlog "pass reported leftovers; digest not stored, will retry on next poll"; return 1; }
  fi
  echo "$digest" > "$CW_STATE/digest"
  sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$hdr" | tr -d '\r' | head -1 > "$CW_STATE/etag"
}

ntfy_listen() {
  local url last=0 now
  [ -r "$CW_NTFY_FILE" ] || { wlog "no ntfy file at $CW_NTFY_FILE — ntfy off"; return 2; }
  url=$(tr -d '\r\n' < "$CW_NTFY_FILE")
  [[ "$url" =~ ^https://[A-Za-z0-9._/-]+$ ]] || { wlog "ntfy file content is not a plain https URL — ntfy off"; return 2; }
  while :; do
    "$CW_CURL" -sSN "$url/json" 2>/dev/null | while IFS= read -r line; do
      case "$line" in *'"event":"message"'*) ;; *) continue ;; esac   # the text is never used
      now=$(date +%s)
      [ $((now - last)) -ge "$CW_MIN_GAP" ] || continue
      last=$now; run_pass "ntfy message" || true
    done
    [ "${CW_NTFY_ONESHOT:-0}" = 1 ] && return 0   # test hook: do not reconnect
    wlog "ntfy stream ended — reconnecting in 30s"; sleep 30
  done
}

main() {
  case "${1:-}" in
    --once) poll_once ;;
    --ntfy) ntfy_listen ;;
    --loop)
      if [ -r "$CW_NTFY_FILE" ]; then ntfy_listen & NTFY_PID=$!; trap 'kill "$NTFY_PID" 2>/dev/null' EXIT; fi
      while :; do poll_once || true; sleep "$CW_POLL_SECS"; done ;;
    *) echo "usage: $0 --once | --ntfy | --loop" >&2; return 64 ;;
  esac
}

main "$@"
