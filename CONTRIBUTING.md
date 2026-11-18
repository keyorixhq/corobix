# Contributing

Thanks for taking a look. This is a solo-maintained project, so response
times aren't guaranteed, but real contributions are genuinely welcome.

## Found a security issue?

Don't open a public issue — see [`SECURITY.md`](SECURITY.md) instead.

## Found a bug (non-security)?

Open a [GitHub Issue](../../issues/new). Please include:
- what you ran (the exact command / `fuzz.conf` you used)
- what you expected vs. what happened
- your Go version and OS

## Proposing a code change

1. Fork, branch off `main`.
2. Make the change.
3. Run the local gate before opening a PR — nothing runs this for you yet
   (see the README's CI note):
   ```sh
   ./scripts/check.sh    # shellcheck fuzz-runner.sh + bats tests/ + go vet + govulncheck targets/*
   ```
4. Open a PR against `main`. Describe *why*, not just *what* — especially
   for anything touching `fuzz-runner.sh`'s crash/report-mode logic, since a
   silent behavior change there can downgrade a finding's confidentiality.

## Proposing a new fuzz target

The runner (`fuzz-runner.sh`) is deliberately generic — it discovers and
drives whatever `Fuzz*` functions exist in the module `MODULE_DIR` points
at. Adding coverage for a new open-source library means adding a new
standalone Go module under `targets/` with real `Fuzz*` test functions, the
same shape as the existing ones in `targets/libs/` and `targets/libs-extra/`
— see [`targets/README.md`](targets/README.md) for the conventions each
target follows (per-input deadline via the shared `withinDeadline` helper,
sound round-trip/rejection invariants, no byte-idempotence assumptions for
formats like XML that legitimately normalize on re-parse).

A couple of things that are maintainer-specific and *not* yours to wire up
in a PR: `CORPUS_REPO` and `REPORT_MODE` in a `fuzz.conf` point at a private
corpus repo used to hold pre-disclosure crash material — contribute the
harness code itself (and a `fuzz.conf` example with `REPORT_MODE=local`),
and the maintainer will take it from there for actually running it against
a live corpus.

## Picking up an open feature branch

There are a few open branches with real, unfinished work (deploy tooling,
shared stall detection, crasher-pull/watch tooling, pin-drift guards) —
check `git branch -r` for what's currently open. If one looks interesting,
open an issue first to say you're looking at it before investing a lot of
time, since direction may still change.

## Code of conduct

Be respectful, assume good faith, keep disagreements about the code and
not the person. Reports of abusive behavior can go to the same contact as
[`SECURITY.md`](SECURITY.md).
