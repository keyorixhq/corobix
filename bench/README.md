# fuzz-bench.sh — portable cross-rig fuzzing benchmark

`bench/fuzz-bench.sh` measures native Go fuzzing throughput, parallel-worker
scaling, and time-to-find effectiveness for keyorix, dashdiag, and libs-extra
targets. It's designed to run unchanged across machines (the vCD rigs, an
OCI Ampere A1 arm64 instance, cloud spot instances) so the numbers actually
compare. It never touches the production fuzz-runner's state — `fuzz.conf`,
systemd units, corpora, `harness-state`/`harness-logs` dirs are all
untouched; everything happens under a scratch dir (`$SCRATCH`, default
`~/bench-work`) that's safe to delete when a run is done.

## Running it

```
fuzz-bench.sh <keyorix|dashdiag> [--dry-run] [--resume-ts <UTC-timestamp>]
```

- `keyorix` runs the keyorix throughput suite (4 targets), the
  parallel-scaling suite (2 of those targets at 1/2/4/nproc workers), and
  the keyorix time-to-find cases.
- `dashdiag` runs the dashdiag collector throughput target and the
  libs-extra time-to-find case. There's no parallel-scaling suite for
  dashdiag — the spec only asks for it on the two keyorix targets.
- `--dry-run` shrinks every duration/cap to ~30s (see the script's `DRY_RUN`
  branch for exact values) and TTF reps to 1. **Always dry-run a role before
  its first full run on a new rig** — the dashdiag role broke on its first
  real full run (see "Known limitations" below) specifically because it had
  only ever been dry-run as `keyorix`, not as `dashdiag`, before that.
- `--resume-ts <ts>` reuses an existing `results/<hostname>/<ts>/` output
  dir instead of starting a new one. Every (suite, target, param, rep) has
  its own done-marker under `.done/`, so a resumed run — after an SSH drop,
  a crash, or a deliberate partial re-run — skips everything already
  recorded and only does the remaining work.

### Running on a new rig

1. Copy the script over (`scp bench/fuzz-bench.sh <rig>:~/bench-work/`) —
   don't put it inside a live fuzz-runner checkout.
2. Override these env vars to point at wherever each source lives on that
   rig (all default to this deployment's actual paths):
   - `GO_BIN` (default `/snap/go/current/bin/go`, falls back to `$(command -v go)`)
   - `KEYORIX_SRC` (default `/opt/keyorix-fuzz/keyorix`)
   - `DASHDIAG_SRC` (default `$HOME/proj/dashdiag`)
   - `LIBSEXTRA_SRC` (default `$HOME/proj/libs-extra-fuzz`)
   - `SCRATCH` (default `$HOME/bench-work`)
   - `COST_PER_HOUR` — pass this on cloud spot/OCI so `hw.txt` records it
     for cost-normalized comparison (empty/unset on the vCD rigs, which
     aren't billed hourly).
3. The script auto-detects whether each source is a real git checkout or a
   flat deployed snapshot (see "Known limitations") — no flag needed.
4. `--dry-run` first, check the CSVs look sane, then the real run:
   ```
   TTF_REPS=3 setsid nohup ./fuzz-bench.sh keyorix > run.log 2>&1 < /dev/null &
   disown
   ```
   `setsid` + closed stdio is what survives an SSH disconnect — the ssh
   session itself may take a while to actually close afterward (harmless;
   that's the local ssh client waiting on the channel, not the benchmark).
   `TTF_REPS` (default 5) and `TTF_CAP_S` (default 3600) are worth tuning
   down if a time-to-find case is expensive and the wall-clock budget is
   tight — cut reps before cutting the cap; a shorter cap changes what
   "not found" means, fewer reps just widens the confidence interval on
   the median.
5. On arm64 (OCI Ampere A1), nothing needs changing — `nproc`, `uname -m`,
   and all the go tooling calls are architecture-agnostic already.

## Output

`results/<hostname>/<UTC-timestamp>/`:

- `hw.txt` — fingerprint: arch, kernel, virtualization, `nproc`, go version,
  `COST_PER_HOUR`, memory, disk, CPU info, plus the pinned commit/provenance
  of every source used.
- `throughput.csv` — `rig,target,parallel,elapsed_s,execs,execs_per_s,new_interesting,total_corpus,peak_rss_kb,build_s,note`.
  One row per target, cold corpus (a fresh clone/copy, so only the
  checked-in seed corpus), fixed 15-minute fuzz window at `-parallel=nproc`.
  A skipped target (e.g. `FuzzStorageBackendDifferential` with no reachable
  Postgres) gets a row with all-zero numeric fields and `note` explaining
  why, never a silently missing row.
- `parallel.csv` — `rig,target,parallel,elapsed_s,execs,execs_per_s,new_interesting,total_corpus,execs_per_s_per_worker`.
  Same two keyorix targets at `-parallel` 1/2/4/nproc, 5 minutes each.
- `ttf.csv` — `rig,case,rep,found,seconds,cap_s`. Each case reverts a
  specific known-fixed bug inside a throwaway scratch copy (never committed,
  never pushed — see "How a TTF case works" below) and times how long cold
  fuzzing takes to rediscover it, capped at `cap_s`. `found=false` with
  `seconds=cap_s` is a legitimate result, not an error — it means the cap
  ran out before fuzzing rediscovered that specific bug. Effectiveness, not
  speed: a case can legitimately never find its bug within any reasonable
  cap if the bug requires a structurally specific input a byte-mutator is
  unlikely to compose from generic seeds (this happened for real — see
  `results/keyorix-fuzz/*/ttf.csv`, case_a, 0/3).
- `raw/*.log`, `raw/*.log.build`, `raw/*.rss` — full `go test -fuzz` output,
  isolated `-c` build-time-only logs, and peak RSS per run.
- `summary.md` — everything above as tables, plus notes (was the runner
  paused, was Postgres reachable, anything skipped and why).
- `notes.txt` — the same notes summary.md's Notes section reads from;
  raw, one line per event, in case you want it outside the rendered form.

### execs_per_s

Computed as `execs / elapsed_s` from the **last** `fuzz: elapsed: ...`
line in the run's log, not the instantaneous rate go itself prints on that
line. Go's per-tick rate trails toward the tick average right at the very
end of a window (an artifact fuzz-runner.sh's own `measured_exec_rate`
already works around the same way), so recomputing from the cumulative
totals is the stable number. `elapsed_s` itself only starts once fuzzing
begins — Go's own build step happens before that clock starts, which is
also why sharing one `GOCACHE` across the whole run (rather than isolating
it per target/parallel-level) doesn't bias throughput numbers, only saves
wall-clock. `build_s` in `throughput.csv` is measured separately, via an
explicit `go test -c` step timed before the fuzz run.

### Comparing across machines

- Normalize by core: `execs_per_s / nproc` (nproc is in `hw.txt`).
  `summary.md`'s throughput table already has this column
  (`execs/s/core`).
- Normalize by cost, if `COST_PER_HOUR` was set: `execs_per_s * 3600 /
  COST_PER_HOUR` gives execs per dollar.
- Compare `parallel.csv`'s `execs_per_s_per_worker` trend across machines to
  see how each core count's marginal value differs (e.g. a 2-OCPU arm64
  instance's per-worker rate at `-parallel=2` vs. a 7-core rig's at the same
  level) — this is the number that answers "is it worth paying for more
  cores on this shape of machine," not raw `execs_per_s`.
- TTF medians are only comparable case-by-case (case_a vs. case_a), never
  across different cases — different bugs have wildly different intrinsic
  discoverability, as the keyorix (case_a, 0/3 found) vs. dashdiag (case_c,
  5/5 found, median 14s) results already show.

## How a TTF case works

Each case pins a fixed commit (or, for a non-git source, whatever the
deployed snapshot currently is), reverts a specific known-fixed bug inside
a throwaway scratch copy, confirms the **unreverted** code runs clean for
`TTF_CONFIRM_CLEAN_S` seconds (so a later "found" really means the restored
bug, not pre-existing noise), then confirms the **reverted** code actually
compiles before trusting any timing from it — a revert that doesn't compile
is a broken fixture, not a "not found" result, and gets skipped with a
clear reason in `notes.txt`/`summary.md` rather than a silently-wrong data
point in `ttf.csv`.

Two revert mechanisms exist, picked per-case:

- **git-based** (keyorix cases): clone the pinned commit fresh, then revert
  every file the fix commit *modified* (not *added*) by reverse-applying
  that commit's own diff to each file — this restores pre-fix behaviour
  while leaving the fix's own new fuzz-test file in place, so the target
  still exists to fuzz. A per-file revert that fails to reverse-apply
  cleanly (e.g. a shared append-only file like
  `docs/security-closures.tsv` that a later, unrelated commit also
  touched) is logged, not silently dropped — see keyorix's
  `results/keyorix-fuzz/*/notes.txt` for a real example. It's harmless
  *if and only if* the actual behaviour-changing file(s) still reverted
  cleanly and the post-revert build check passes; both are checked, not
  assumed.
- **plain-copy-based** (the libs-extra case): the source has no `.git` at
  all — it's a flat deployed snapshot (see "Known limitations") — so
  there's no commit to revert. The "revert" is a dependency downgrade
  (`go mod edit -require=... @<old-vulnerable-version>` + `go mod tidy`)
  instead of a file patch.

Between reps, the corpus resets to cold (the checked-in seed corpus only,
not whatever the previous rep discovered) — via `git clean` for a git-based
case, via a saved/restored snapshot for a copy-based one, since there's no
git history to clean against.

## Known limitations

- **case_b (keyorix `FuzzDEKSweepCrashConsistency`, PR #1918) is not run —
  it's structurally unrevertible by this script's file-level revert.** Its
  own regression test calls `RecoverInterruptedRotation`, a method PR #1918
  itself introduces as part of the fix. Reverting the fix removes that
  method; the kept fuzz test still calls it; the reverted tree doesn't
  compile. This isn't a bug in the revert mechanism — it's what happens
  when a regression test is written to exercise the *new* recovery path
  directly rather than parametrizing over old/new behaviour. Confirmed live
  (see `results/keyorix-fuzz/*/notes.txt` and
  `raw/ttf-case_b__FuzzDEKSweepCrashConsistency_pr1918-postrevert-build.log`).
  Making this case work would need a hand-authored partial patch (keep
  `PromotePendingDEK`/`RecoverInterruptedRotation` defined but make them
  behave like the old `CleanPendingDEK`), which is a one-off, not something
  a generic "revert every modified file" mechanism can derive — not
  attempted here, since a partial hand-patch is exactly the kind of thing
  this script can't verify it got right without the same depth of review
  the original fix itself got.
- **`libs-extra-fuzz` is not a git checkout on the dashdiag rig** — it's a
  flat rsync/scp-deployed snapshot (a `DEPLOYED_FROM.txt` marker, no
  `.git`), unlike `keyorix`/`dashdiag` which are real checkouts. The script
  auto-detects this (`copy_pinned`/`record_provenance` fall back
  gracefully) so this is handled, not a limitation exactly — noted here
  because it's the reason `KEYORIX_SRC`/`DASHDIAG_SRC`/`LIBSEXTRA_SRC`
  can't all be assumed to behave the same way on a new rig, and why this
  script dry-runs each role independently rather than assuming validating
  one role validates the other.
- `FuzzStorageBackendDifferential` (keyorix throughput) needs a reachable
  Postgres at `KEYORIX_TEST_PG_DSN` (defaulted to this deployment's local
  DSN, `host=127.0.0.1 port=59432 ...` — override if a rig's PG lives
  elsewhere). No PG ⇒ skipped with a `note` in `throughput.csv`, not a
  silently-missing row.
