# vCD rig migration onto fuzz-harness

Migrating the two live vCD fuzz rigs from their bespoke runners onto the
universal `fuzz-runner.sh`. Prepared 2026-09-13.

| box | old runner | module | mem cap | current model |
|-----|-----------|--------|---------|---------------|
| `vcd-dashdiag-fuzz` | `dashdiag/scripts/fuzz-continuous.sh` | `/home/andrei/proj/dashdiag` | 6500M | auto-discover all, uniform 15m, crashers→PR |
| `vcd-keyorix-fuzz` | `keyorix/scripts/fuzzing/run-rotation.sh` | `/opt/keyorix-fuzz/keyorix` | 5500M | curated `targets.conf`, tuned durations, crashers→PR, **+ corpus→`fuzz-corpus` branch** |

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

## ⚠️ keyorix decision: corpus-branch persistence

The keyorix rig alone continuously commits its **growing corpus** to a
`fuzz-corpus` git branch (worktree `/opt/keyorix-fuzz/keyorix-fuzz-corpus`, via
`config.env`'s `FUZZ_CORPUS_WORKTREE`). The universal runner does **not** do
this — it persists only *crash reproducers* (→ PR), like dashdiag. Migrating
keyorix as-is means the continuous off-box corpus backup stops (the corpus stays
locally in GOCACHE and in the 2026-09-13 Mac archive, but is no longer streamed
to a branch).

At current saturation (~90%+, corpus growth on the asymptotic tail, 0 crashers)
the marginal value of continuous corpus streaming is low. Options:

- **A — dashdiag now, hold keyorix**: cut over dashdiag (clean, zero feature
  loss); keep keyorix on its bespoke runner until the universal runner grows a
  corpus-sync feature. No regression.
- **B — migrate both now, accept the gap**: simplest end state (one runner
  everywhere); keyorix loses continuous corpus-branch backup. Acceptable given
  saturation + the Mac archive.
- **C — add corpus-sync to the runner first, then migrate both**: no regression,
  true superset, but a new runner feature to build + test.

Recommendation: **A now, then C** (build corpus-sync, then migrate keyorix).

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

### keyorix (only if choosing option B)

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

- keyorix: PR removing `scripts/fuzzing/run-rotation.sh` + `targets.conf` (and
  the `keyorix-fuzz` corpus-sync bits) — **only if option B/C chosen**.
- dashdiag: PR removing `scripts/fuzz-continuous.sh` (keep `fuzz-discover.sh` —
  the Makefile/CI still use it).

Nothing auto-merges; review like any other PR, merge on green.
