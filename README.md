# fuzz-harness

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

## Why native `go test -fuzz`

For pure-Go / CGO-free code the libFuzzer sanitizer advantage (ASan/MSan/UBSan)
does not apply, and the native engine needs no build plumbing, ships in the
toolchain, and shares the same corpus format everywhere. Discovery uses the
same `go test -list '^Fuzz'` the CI job uses, so the rig can never silently
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

## Crash handling: `local` vs `pr`

- `local` — move the reproducer into `FINDINGS_DIR/<Func>/<ts>/` and notify.
  Nothing is published. **This is forced for `SOURCE_MODE=standalone`**
  (third-party libraries) unless `ALLOW_PR_FOR_STANDALONE=1`, because a crash in
  someone else's library is potential-0-day disclosure material, not a PR.
- `pr` — re-sync, commit the reproducer (DCO `--signoff`) to `CORPUS_BRANCH`,
  push, and open a PR against `GIT_BRANCH`. For our own repos in `git` mode.

## Configuration

All keys are set in `fuzz.conf`. Only `MODULE_DIR` is required.

| key | default | meaning |
|-----|---------|---------|
| `MODULE_DIR` | *(required)* | Go module root to fuzz. |
| `SOURCE_MODE` | `standalone` | `git` (sync a repo each cycle) or `standalone` (fuzz the tree as-is). |
| `CRASH_MODE` | `local` | `local` (private findings) or `pr` (open a PR). Forced to `local` for `standalone`. |
| `ALLOW_PR_FOR_STANDALONE` | `0` | Set `1` to allow `pr` mode on a standalone module (rare; overrides the disclosure guard). |
| `DEFAULT_FUZZTIME` | `15m` | Per-target fuzztime when no override is set. |
| `DURATION_<Func>` | — | Per-target fuzztime override, e.g. `DURATION_FuzzVerifyReceipt=3h`. |
| `PARALLEL` | `4` | `go test -parallel`. |
| `GIT_REMOTE` / `GIT_BRANCH` | `origin` / `main` | Sync source (git mode). |
| `CORPUS_BRANCH` | `fuzz/corpus-updates` | Branch for crash-reproducer PRs (pr mode). |
| `STATE_DIR` / `LOG_DIR` / `FINDINGS_DIR` | `$MODULE_DIR-{state,logs,findings}` | Working dirs. |
| `NOTIFY_URL` | — | Optional; `curl -d <msg>` fired on crash. |
| `FETCH_RETRIES` / `FETCH_BACKOFF` | `5` / `10` | git-mode fetch retry/backoff (linear). |

See `examples/` for `standalone` (libs), `git`+`pr` (dashdiag), and
`git`+`pr`+overrides (keyorix) configs.

## Testing

`fuzz-runner.sh` sources cleanly for unit testing via the `FUZZ_RUNNER_LIB`
hook (it `return`s before `main` when that variable is set). Pure functions
(`resolve_duration`, `effective_crash_mode`) are covered by `tests/*.bats`.
CI runs `shellcheck` + `bats` on every push (`.github/workflows/ci.yml`).

```sh
shellcheck fuzz-runner.sh
bats tests/
```

## Layout

```
fuzz-runner.sh                     the runner
examples/{libs,dashdiag,keyorix}.conf
templates/fuzz-rig.service.tmpl    systemd unit template
tests/runner.bats                  unit tests for the pure functions
.github/workflows/ci.yml           shellcheck + bats
```
