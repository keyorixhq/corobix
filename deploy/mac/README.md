# Mac-side crasher puller (crasher-pull.sh + crasher-watch.sh)

Pulls new crashers off the vCD fuzz hosts (`~/lane/crashers/<target>/<hash>/`) into a
local quarantine, verifies a content hash, and only then deletes the host copy. The hosts
are treated as already compromised: they get no new credential, the Mac only ever pulls.

```
trigger (issue activity | ntfy | 10-min schedule | login)  ->  "run a pass now", nothing else
pass: list (fixed hosts file) -> hash on host -> rsync -> hash on Mac == host hash?
      -> mv into quarantine -> ledger line -> SEPARATE ssh: re-verify hash on host, rm -rf
```

## What it will and will not do
- Hosts come only from `deploy/mac/crasher-pull.hosts` (reviewed file in this repo). The
  puller accepts no host, path or command argument; the watcher starts it with **no arguments**.
  Text from an issue or an ntfy message is never used for anything (not even logged).
- Names listed by a host are untrusted: only `<target>` = `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` and
  `<hash>` = `[0-9a-f]{8,64}` are accepted; anything else is skipped, reported, left alone.
- Any failure (ssh, copy, hash mismatch, changed-in-flight, delete refused) leaves the host
  copy. Re-running is safe: a crasher already in quarantine is re-verified and its host copy
  deleted without a second copy or ledger line.
- It never opens PRs, issues or comments.

## Where things live (all on the Mac, outside any git checkout)
| What | Path |
|---|---|
| quarantine | `~/crasher-quarantine/<host>/<target>/<hash>/` (+ `<hash>.DO-NOT-PUBLISH` for third-party targets) |
| ledger (append-only TSV: time, host, target, hash, `pulled-ok` / `host-deleted`, `third-party` or `-`) | `~/.crasher-pull/ledger.tsv` |
| logs | `~/.crasher-pull/pull.log`, `watch.log` |
| issues token (read-only `issues:read` on keyorixhq/fuzz-corpus; contents never in the repo) | `~/.config/crasher-pull/issues-token` |
| ntfy topic URL (optional, one `https://...` line) | `~/.config/crasher-pull/ntfy-url` |
| third-party targets | `deploy/mac/crasher-pull.third-party` (**placeholder names, verify**) |

## Install (Andrei, once; the sandbox session could not run launchd)
```sh
cd <this checkout of corobix>
scripts/check.sh                       # or: bats tests/crasher-pull.bats tests/crasher-pull-redproof.bats

# 1. ssh: aliases vcd-keyorix-fuzz and vcd-dashdiag-fuzz must work non-interactively
#    (BatchMode) in ~/.ssh/config, with the bastion as ProxyJump, exactly as for manual pulls.
ssh -o BatchMode=yes vcd-keyorix-fuzz true && ssh -o BatchMode=yes vcd-dashdiag-fuzz true

# 2. look first: a dry run changes nothing (no copy, no ledger, no delete)
./crasher-pull.sh --dry-run

# 3. token + optional ntfy (create the files yourself; never paste them anywhere)
mkdir -p ~/.config/crasher-pull ~/.crasher-pull
chmod 700 ~/.config/crasher-pull
#   ~/.config/crasher-pull/issues-token   (chmod 600)   ~/.config/crasher-pull/ntfy-url (optional)

# 4. the FIRST REAL PULL, by hand, watching it
./crasher-pull.sh

# 5. launchd (fill in the two paths)
D="$PWD"
for j in crasher-pull crasher-watch; do
  sed -e "s|__INSTALL_DIR__|$D|g" -e "s|__HOME__|$HOME|g" deploy/mac/com.keyorix.$j.plist \
    > ~/Library/LaunchAgents/com.keyorix.$j.plist
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.keyorix.$j.plist
done
launchctl list | grep keyorix.crasher     # both listed
tail -f ~/.crasher-pull/pull.log
```
Uninstall: `launchctl bootout gui/$(id -u)/com.keyorix.crasher-pull` (same for `-watch`), delete the plists.

## Known limits (read before the first real pull)
- Tested against fake hosts (local dirs behind ssh/rsync/curl shims), not a real host, the
  bastion, GitHub or ntfy. macOS ships openrsync; the rsync flags are the minimal `-rt --timeout`.
- A host that streams unbounded data can fill the Mac disk: there is no size cap yet.
- Symlinks and special files on the host make that crasher refuse (it stays on the host and
  is reported); an `a/..`-style trick cannot reach the Mac because names are validated.
- The hash is a per-file sha256 manifest of the directory, not a signature: it detects
  corruption and in-flight change, not a host that lies consistently.
