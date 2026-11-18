#!/usr/bin/env bash
# fuzz-report.sh: one shared message shape for every fuzz-crash notification in
# this repo, so the same ntfy topic reads consistently regardless of which
# script or host sent it.
#
# This does NOT redefine notify()/log() — fuzz-runner.sh and fuzz-lane.sh keep
# their own (genuinely different: fuzz-runner's is a plain curl, fuzz-lane's
# adds ntfy Title/Priority headers). This file only builds the message BODY
# string; callers pass that string into whichever notify() they already have.
#
# Usage: fuzz_report_msg <mode> <target> <pkg> [path] [extra]
#   mode   - "local" | "private" | "issue" | "public PR" | "lane" | any free text
#   target - fuzz function name
#   pkg    - package path (Go import path)
#   path   - local path to the kept reproducer bytes. OMIT for "issue" mode:
#            that mode's whole point is a public repro *pointer* that never
#            discloses where the raw crashing input lives (disclosure safety,
#            see fuzz-runner.sh's handle_crash()). Every other mode should
#            pass it — a local copy is always kept before any push/report, so
#            there is always a path to show except in issue mode.
#   extra  - optional trailing context, e.g. "at <commit> (<ref>)" or
#            "pushed to <project>". Appended after a "; ".
#
# Output shape: "<host> CRASH (<mode>) <target> in <pkg>[ -> <path>][; <extra>]"
fuzz_report_msg() {
  local mode="$1" target="$2" pkg="$3" path="${4:-}" extra="${5:-}"
  local host="${HOST:-$(hostname)}"
  local msg="$host CRASH ($mode) $target in $pkg"
  [ -n "$path" ] && msg="$msg -> $path"
  [ -n "$extra" ] && msg="$msg; $extra"
  printf '%s' "$msg"
}
