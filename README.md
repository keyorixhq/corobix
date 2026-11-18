# corobix

A thin, universal continuous-fuzz **rotation runner** for Go projects using the
native fuzzing engine (`go test -fuzz`). One `fuzz-runner.sh` + one `fuzz.conf`
drives a long-running rig that discovers every `Fuzz*` target in a module,
fuzzes them one at a time in a loop, and either files crash reproducers
privately or opens a PR — depending on the module.

This is **not** a fuzzing platform. It is deliberately ~130 lines of bash with
no daemon, no database, no web UI. It exists so that standing up a new soak rig
(own code on own hardware, or a third-party library) is a config file, not a
new script. See the design rationale and the "when to reach for something
heavier" triggers in the Keyorix project doc
`claude/2026-09-13-fuzzing-tooling-decisions.md`.

<!-- STATS:BEGIN (auto-updated by registry/gen_public_stats.py — don't hand-edit) -->
**So far: 9 vulnerabilities + 53 other defects found across 34 open-source Go libraries** via continuous fuzzing — see [`STATS.md`](STATS.md) for the breakdown by severity and category, and links to the ones already publicly disclosed. Regenerated periodically from an internal registry.
<!-- STATS:END -->

## Why native `go test -fuzz`

For pure-Go / CGO-free code the libFuzzer sanitizer advantage (ASan/MSan/UBSan)
does not apply, and the native engine needs no build plumbing, ships in the
toolchain, and shares the same corpus format everywhere. Discovery uses the
same `go test -list '^Fuzz'` the runner uses, so the rig can never silently
drift out of sync with the target set (a hardcoded list once missed 18 of 44
targets — this design removes that failure mode).

## Quick start

```sh
cp examples/libs.conf fuzz.conf     # edit MODULE_DIR + paths
./fuzz-runner.sh                     # runs in the foreground; Ctrl-C to stop
```

For a long-lived rig, run it under systemd — see `templates/fuzz-rig.service.tmpl`.

## How it works

1. Source `fuzz.conf` (path from `$FUZZ_CONF`, else beside the script).
2. In `git` mode, `sync_main` to the tracked branch (non-fatal — a fetch blip
   fuzzes the existing checkout rather than taking the rig down).
3. `discover` all `pkg|Func` targets via `go list ./...` + `go test -list`.
4. Rotate: fuzz each target for its duration (`DURATION_<Func>` override, else
   `DEFAULT_FUZZTIME`), persist the rotation position so a restart resumes
   mid-cycle instead of always starting from target 0.
5. After each run, a **reproducer under `testdata/fuzz/<Func>`** — not merely a
   nonzero exit — is what counts as a crash. End-of-fuzztime deadline exits are
   logged, not alerted.
6. Self-reload: at the top of each cycle, if `fuzz.conf` changed or the target
   set changed, `exec` itself (resuming from the saved rotation position).

## Crash handling: `local` / `private` / `pr`

A reproducer is **always** copied to `FINDINGS_DIR/<Func>/<ts>/` first, so a
push failure can never lose it. Then, by `CRASH_MODE`:

- `private` (recommended) — push the reproducer to the **private** `CORPUS_REPO`
  under `crashers/<project>/<pkg>/<Func>/<ts>/` (append-only) and notify. Keeps
  an unfixed vuln — our own code *or* a third-party library — out of public view
  until the fix ships; the reproducer becomes a public regression test only
  after the bug is fixed. Non-fatal if the push fails (kept local + notified).
- `local` — findings dir + notify only. Nothing leaves the box.
- `pr` — **PUBLIC**: commit the reproducer (DCO `--signoff`) to `CORPUS_BRANCH`,
  push, open a PR against `GIT_BRANCH`. Only for own code you're willing to
  disclose immediately. **Refused for `SOURCE_MODE=standalone`** (third-party) —
  downgraded to `private` (if `CORPUS_REPO` set) else `local`, unless
  `ALLOW_PR_FOR_STANDALONE=1`.

## Corpus backup (`CORPUS_SYNC`)

With `CORPUS_SYNC=on`, once per rotation cycle the runner mirrors `$GOCACHE/fuzz`
(the growing "interesting" corpus — weeks of accumulated coverage inputs,
otherwise only ever on one box) into `corpus/<project>/` on the private
`CORPUS_REPO`'s **`main`** branch. Everything lives on `main` — corpus under
`corpus/<project>/`, crashers under `crashers/<project>/` — so it's all in one
place with no branches or PRs to chase. Each rig writes only its own subtree and
pushes with fetch/reset retry, so concurrent rigs (disjoint subtrees) never
clobber each other. Corpus files are content-addressed, so git dedups unchanged
files across commits and cross-rig merge is a dedup-by-name union. **The
destination must be private** — an interesting-corpus input is a
near-coverage-boundary input, sensitive for undisclosed third-party code.
Non-fatal.

## Saturation report (`SATURATION_REPORT`)

With `SATURATION_REPORT=on`, the runner records each target's per-run
new-interesting count and — at most once per `SATURATION_REPORT_INTERVAL` — pushes
a digest to `NOTIFY_URL` summing the last `SATURATION_WINDOW` runs per target
(`SATURATED (+0 over N runs)` / `active (+K over N runs)` / `warming`). This is
**advisory only**: it never drops or deweights a target — a human reads it and
decides whether to add something to `EXCLUDE`. Deliberately not automatic:
coverage plateaus break, and a crash can surface at flat coverage, so "stopped
growing" is not a safe signal to stop fuzzing on its own.

## Configuration

All keys are set in `fuzz.conf`. Only `MODULE_DIR` is required.

| key | default | meaning |
|-----|---------|---------|
| `MODULE_DIR` | *(required)* | Go module root to fuzz. |
| `SOURCE_MODE` | `standalone` | `git` (sync a repo each cycle) or `standalone` (fuzz the tree as-is). |
| `CRASH_MODE` | `local` | `local` / `private` (push to `CORPUS_REPO`) / `pr` (public PR). `pr` refused for `standalone`. |
| `ALLOW_PR_FOR_STANDALONE` | `0` | Set `1` to allow public `pr` mode on a standalone module (rare; overrides the disclosure guard). |
| `CORPUS_SYNC` | `off` | `on` backs up `$GOCACHE/fuzz` to `CORPUS_REPO` once per cycle. |
| `CORPUS_REPO` | — | Private git repo for crashers (private mode) and corpus snapshots. |
| `CORPUS_PROJECT` | `basename $MODULE_DIR` | Namespace under the corpus repo (`keyorix`/`dashdiag`/`libs`). |
| `EXCLUDE` | — | Space-separated `Fuzz*` func names to drop from rotation (e.g. a saturated target on a pinned lib). Whole-name match. **Quote it when listing more than one** (`EXCLUDE="FuzzA FuzzB"`) — the conf is sourced as shell. |
| `SATURATION_REPORT` | `off` | `on` pushes a periodic per-target growth digest to `NOTIFY_URL` (advisory; never excludes). |
| `SATURATION_REPORT_INTERVAL` | `21600` | Min seconds between digests (default 6h). |
| `SATURATION_WINDOW` | `10` | Recent runs the verdict sums over. |
| `DEFAULT_FUZZTIME` | `15m` | Per-target fuzztime when no override is set. |
| `DURATION_<Func>` | — | Per-target fuzztime override, e.g. `DURATION_FuzzVerifyReceipt=3h`. |
| `PARALLEL` | `4` | `go test -parallel`. |
| `GIT_REMOTE` / `GIT_BRANCH` | `origin` / `main` | Sync source (git mode). |
| `CORPUS_BRANCH` | `fuzz/corpus-updates` | Branch for public crash-reproducer PRs (`pr` mode only). |
| `GIT_AUTHOR` / `GIT_EMAIL` | `Andrei Beshkov` / `andrey.beshkov@gmail.com` | Author for rig-made commits. |
| `STATE_DIR` / `LOG_DIR` / `FINDINGS_DIR` | `$MODULE_DIR-{state,logs,findings}` | Working dirs. |
| `NOTIFY_URL` | — | Optional; `curl -d <msg>` fired on crash. |
| `FETCH_RETRIES` / `FETCH_BACKOFF` | `5` / `10` | git-mode fetch retry/backoff (linear). |
| `FUZZ_PREBUILT` | `0` | `1` builds each fuzz-target package's test binary once per commit (`go test -c -fuzz='^Fuzz$'`, for the coverage instrumentation fuzzing needs — see fuzz-runner.sh's own comment above `discover()`) instead of recompiling on every slice and every rotation lap. Default off = today's unchanged per-slice `go test` behavior. |
| `PREBUILT_DIR` | `$MODULE_DIR-prebuilt` | Where prebuilt generations live, keyed by commit SHA (or a content hash outside git). Keeps the 2 most recent. MUST stay outside `$(go env GOCACHE)` — Go's own build-cache trimming can evict files under GOCACHE. |
| `MINIMIZE_CAP` | `off` | `on` passes `-fuzzminimizetime=$MINIMIZE_CAP_VALUE` (prebuilt: `-test.fuzzminimizetime`) to targets whose package's coverage map exceeds `MINIMIZE_CAP_THRESHOLD` bytes. The size is measured, never configured: the distance between `internal/fuzz._counters` and `._ecounters` in the instrumented test binary, recorded per prebuilt generation (`mapsizes.tsv`) or measured once per commit and package and cached in `$STATE_DIR/mapsize/`. Unknown size = Go's default, logged. Why: on 250-480 KB maps Go's 60s default minimization stalled keyorix targets 19-67% of wall time; 100x removed it on pure targets (30% left on the stateful HTTP sequence) with identical coverage. Evidence: Keyorix project doc `claude/2026-09-23-coverage-map-leaf-package-ab-results.md`. |
| `MINIMIZE_CAP_VALUE` | `100x` | Any `-fuzzminimizetime` value (`100x` = attempts, `10s` = time, `0` = off). |
| `MINIMIZE_CAP_THRESHOLD` | `100000` | Map bytes above which the cap applies (strictly greater). A package with few imports is ~5 KB. |
| `MINIMIZE_TIME_<slug>` | — | Per-package override of the minimize-time value, wins over `MINIMIZE_CAP_VALUE` for that package only. `<slug>` is the package import path with every non-`[A-Za-z0-9_]` character (`.`, `/`) replaced by `_` (e.g. `github.com/keyorixhq/keyorix/server/http` -> `MINIMIZE_TIME_github_com_keyorixhq_keyorix_server_http=10x` or `=0`). Still gated on `MINIMIZE_CAP=on`. Why: the default 100x was measured on pure targets only; the one stateful target measured (server/http's HTTP sequence fuzzer) only dropped from 66.7% to 30.3% stalled at 100x — a heavy stateful package may want a different cap once real rig numbers are in, without changing the default every other (pure) package benefits from. |
| `CONCURRENT_TARGETS` | `off` | `on` lets the runner fuzz more than one target at once for a single rotation slot, when the CURRENT target is "slow" (see `CONCURRENT_SLOW_THRESHOLD`) and one or more of the IMMEDIATELY FOLLOWING targets in the (sorted) rotation are slow too — a contiguous run only, never an arbitrary scan across the whole list (see fuzz-runner.sh's comment above `is_slow_target` for why). Why: a target whose per-exec cost is dominated by a shared DB handle / KDF / fsync path barely gets faster from raising `-parallel` within its OWN process, leaving cores idle on a multi-core rig while it fuzzes alone. Each grouped target still gets its OWN `resolve_duration`/minimize-cap decision and its OWN log file — nothing else about a target's own slice changes, only that its slice now runs alongside its slow neighbors' slices instead of before or after them. |
| `CONCURRENT_SLOW_THRESHOLD` | `20` | A target counts as "slow" once its last-measured execs/s (the same history `resolve_duration`/`is_saturated` already read) is nonzero and below this. A target with no measured rate yet (unknown) is never treated as slow, so a brand-new target's first run is unaffected. |
| `CONCURRENT_MAX_TARGETS` | `3` | Group size cap (floored at 2 — a "group" of 1 is a no-op by construction). |

See `examples/` for `standalone`+`private` (libs), and `git`+`private`(+overrides)
for dashdiag / keyorix.

## Testing

`fuzz-runner.sh` sources cleanly for unit testing via the `FUZZ_RUNNER_LIB`
hook (it `return`s before `main` when that variable is set). Pure functions
(`resolve_duration`, `effective_crash_mode`) are covered by `tests/*.bats`.
Hosted CI is disabled for this repo — run the checks locally before every PR:

```sh
./scripts/check.sh    # shellcheck fuzz-runner.sh + bats tests/ + go vet + govulncheck targets/*
```

**No PR check runs any of this automatically, and no branch protection enforces it yet**
(branch protection was 403-blocked while this repo was private on the org's free plan —
"Upgrade to GitHub Pro or make this repository public" — and it's now public, so that's no
longer the blocker; protection just hasn't been configured yet). A merged PR being green means
nothing here was checked; it means nothing ran at all. Run `scripts/check.sh` yourself before
every PR, and don't infer "checked" from a PR's status.

Why there's no hosted workflow (historical note): this repo was private until
2026-11-18, and the org had no paid Actions allowance for private repos on
the free plan, so a `ci.yml` here would have billing-blocked every run
instead of executing it (confirmed at the time: zero Actions usage ever
recorded in the org's billing history, and `actions/permissions` reported
`enabled: false`). The repo is now **public**, which gets unlimited free
Actions minutes on GitHub-hosted runners regardless of plan — the original
blocker is gone. A `ci.yml` wiring up `scripts/check.sh` on push/PR hasn't
been added yet; that's a deliberate next step, not an oversight.

## Layout

```
fuzz-runner.sh                     the runner
examples/{libs,dashdiag,keyorix}.conf
templates/fuzz-rig.service.tmpl    systemd unit template
tests/runner.bats                  unit tests for the pure functions
scripts/check.sh                   local pre-PR gate (shellcheck + bats + go vet + govulncheck)
targets/{libs,libs-extra}/         standalone third-party-lib fuzz target modules
```

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
