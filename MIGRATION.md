# vCD rig migration onto fuzz-harness

Migrating the two live vCD fuzz rigs from their bespoke runners onto the
universal `fuzz-runner.sh`. Prepared 2026-09-13.

| box | old runner | module | mem cap | current model |
|-----|-----------|--------|---------|---------------|
| `vcd-dashdiag-fuzz` | `dashdiag/scripts/fuzz-continuous.sh` | `/home/andrei/proj/dashdiag` | 6500M | auto-discover all, uniform 15m, crashers→PR |
| `vcd-keyorix-fuzz` | `keyorix/scripts/fuzzing/run-rotation.sh` | `/opt/keyorix-fuzz/keyorix` | 5500M | curated `targets.conf`, tuned durations, crashers→`fuzz-corpus` branch |

## Validation done (non-destructive)

- `fuzz-runner.sh` deployed to `/home/andrei/proj/fuzz-harness/` on both boxes
  (sha256 matches the committed runner), plus a box-local `fuzz.conf` beside it.
- **dashdiag parity: IDENTICAL** — universal `discover()` finds the same 55
  targets as dashdiag's own `scripts/fuzz-discover.sh all`.
- **keyorix parity: MATCH** — the module has exactly 12 `Fuzz*` funcs in source,
  identical to `scripts/fuzzing/targets.conf`; the box-local conf reproduces the
  rebalanced durations (VerifyReceipt 3h, RFC3161Anchor 2h, OIDC 2h, rest 1h).
- Current unit files + drop-ins backed up on each box under
  `~/fuzz-migrate-backup/<ts>/` (for rollback).
- Corpus is safe either way: native fuzz corpus lives in `GOCACHE`
  (`~/.cache/go-build/fuzz`, ~175–178M each) and is untouched by the cutover.

## Corpus persistence: what each rig actually does (corrected)

Earlier notes claimed keyorix "streams its growing corpus" — that was wrong.
keyorix's `sync-corpus.sh` rsyncs only `*/testdata/fuzz/` dirs (i.e. **crash
reproducers**) to the `fuzz-corpus` branch; its own comment: *"Non-crashing
'new interesting' corpus stays in the local build cache (`$GOCACHE/fuzz`) and is
never written into the tree."* So keyorix streams **crashers to a branch**,
functionally the same as dashdiag/the universal runner streaming crashers to a
**PR** — just a different delivery channel.

**No rig backs up the growing (interesting) corpus off-box.** It lives only in
`$GOCACHE/fuzz` (~175–178M/box) plus the one-off 2026-09-13 Mac archive. This is
a real single-point-of-loss (box death / cache eviction ⇒ re-fuzz from seeds),
and the motivation for the CORPUS_SYNC feature below.

Migration consequence: keyorix has **no corpus-growth feature to lose**.

## Disclosure posture change: own-code crashers go PRIVATE (implemented)

Own-code crashers previously went **public** (dashdiag PRs / keyorix's
`fuzz-corpus` branch push) — an unfixed vuln disclosed before the fix. All rigs
now use **`CRASH_MODE=private`**: the reproducer is kept locally *and* pushed to
the private **`keyorixhq/fuzz-corpus`** repo (`crashers/<project>/...`), never a
public PR. It becomes a public regression test only after the fix ships. (No
crashers exist today and no public crasher branch/PR was ever created, so this
is preventive — nothing to clean up.)

## CORPUS_SYNC (growing-corpus backup) — IMPLEMENTED

`CORPUS_SYNC=on` mirrors `$GOCACHE/fuzz` once per cycle into `corpus/<project>/`
on the **`main`** branch of the private `keyorixhq/fuzz-corpus` repo (crashers go
to `crashers/<project>/` on the same branch). Everything on one branch — no
corpus branches, no PRs. Each rig writes only its own subtree and pushes with
fetch/reset retry (disjoint subtrees never clobber). Content-addressed files ⇒
git dedups unchanged inputs across commits; cross-rig merge is dedup by name.
`keyorixhq/fuzz-corpus` is **private with Actions disabled**, so it stores corpus
without consuming any CI minutes.

### Credentials — per-rig SSH deploy keys (DONE)

Each rig has a dedicated write deploy key on `fuzz-corpus`, isolated behind SSH
host alias `github-fuzzcorpus` (`migration/provision-deploy-key.sh`); confs use
`CORPUS_REPO=git@github-fuzzcorpus:keyorixhq/fuzz-corpus.git`. Org deploy-key
policy was enabled; all three keys registered (`ro=false`) and verified
(`git ls-remote` rc=0). The keyorix/dashdiag PAT is left untouched. pve is live
and pushing; the vCD rigs push once cut over.

## Cutover (needs sudo — run by Andrei)

`andrei` has no passwordless sudo on these boxes, so the systemd steps below
must be run interactively. The runner + conf are already staged; the drop-in
override (changes only `ExecStart`, keeps User/PATH/memory caps/env) is staged
at `~/fuzz-migrate-staging/10-harness.conf` on each box.

### dashdiag (safe, recommended now)

```sh
ssh vcd-dashdiag-fuzz
sudo install -m0644 ~/fuzz-migrate-staging/10-harness.conf \
  /etc/systemd/system/dashdiag-fuzz.service.d/10-harness.conf
sudo systemctl daemon-reload
sudo systemctl restart dashdiag-fuzz.service
# verify
systemctl status dashdiag-fuzz.service --no-pager | head
journalctl -u dashdiag-fuzz.service -n 40 --no-pager     # expect "discovered 55 target(s)"
```

### keyorix (also clean — crashers move from a branch push to a PR)

```sh
ssh vcd-keyorix-fuzz
sudo install -m0644 ~/fuzz-migrate-staging/10-harness.conf \
  /etc/systemd/system/keyorix-fuzz.service.d/10-harness.conf
sudo systemctl daemon-reload
sudo systemctl restart keyorix-fuzz.service
systemctl status keyorix-fuzz.service --no-pager | head
journalctl -u keyorix-fuzz.service -n 40 --no-pager       # expect "discovered 12 target(s)"
```

### Verify (both)

- `journalctl` shows `discovered N target(s); mode=git/pr` then
  `=== fuzzing <Func> ... ===` lines.
- `systemctl show <unit> -p MemoryMax --value` still reports the cap
  (5767168000 keyorix / 6815744000 dashdiag) — the memory drop-ins are
  untouched.
- The rotation position file appears under the conf's `STATE_DIR`.

## Rollback (needs sudo)

```sh
sudo rm /etc/systemd/system/<unit>.service.d/10-harness.conf
sudo systemctl daemon-reload
sudo systemctl restart <unit>.service
```

The bespoke runner scripts are left in place (not deleted), so removing the
drop-in fully restores the previous rig.

## After a clean soak — retire the bespoke runners (PRs, review-gated)

Once both rigs run green on the universal runner for a full cycle:

- keyorix: PR removing `scripts/fuzzing/run-rotation.sh`, `targets.conf`, and
  `sync-corpus.sh` (its crasher→branch mechanism is superseded by crasher→PR).
- dashdiag: PR removing `scripts/fuzz-continuous.sh` (keep `fuzz-discover.sh` —
  the Makefile/CI still use it).

Nothing auto-merges; review like any other PR, merge on green.
