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

Migration consequence: keyorix has **no corpus-growth feature to lose**. Both
rigs are clean to cut over now; the only keyorix change is crashers land as a
**PR** (review-gated) instead of a branch push — an improvement.

## Planned: universal CORPUS_SYNC (growing-corpus backup) — NEW capability

Opt-in `fuzz.conf` block: on a cadence (default once/cycle, not per-target),
snapshot `$GOCACHE/fuzz` to a durable destination; Go corpus files are
content-addressed (hash filenames) so cross-rig merge is a dedup-by-name union.

- **Disclosure hard rule**: for `SOURCE_MODE=standalone` (third-party libs) the
  destination MUST be private — an interesting-corpus input is a
  near-coverage-boundary input for someone else's undisclosed code. Same logic
  as the forced `CRASH_MODE=local`. Default off; if enabled for standalone,
  force a private target and refuse a public one.
- **Mechanism (decision)**: rsync/tar snapshot to object store or NAS
  (recommended — no git bloat, trivial union for 175M of tiny files) vs a
  force-pushed orphan `fuzz-corpus-cache` branch (in-repo, but history bloat).

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
