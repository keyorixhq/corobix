# crossversion/ — dependency-bump differential replay

`replay-diff.sh` answers a question a version bump on its own cannot: **did
this dependency update change *behavior*, not just a version string?**

`scripts/check-shared-pins.sh` (repo root) already makes a harness pinning a
STALE version relative to keyorix loud. This is the complementary piece: given
an old and a new version of one or more co-moving modules, it builds two
copies of a `targets/*/` module, pins each copy to one side, replays the
SAME corpus (the module's committed `testdata/fuzz/<FUNC>/` seeds, its
`f.Add` seeds, plus any files passed with `--corpus-file`) through the named
`Fuzz` function under both via `go test -run '^FUNC$' -v` (no `-fuzz` — this
replays the recorded corpus as ordinary subtests, it does not mutate), and
flags any input whose accept/reject, crash/no-crash, or deadline/no-deadline
verdict differs between the two.

## Usage

```sh
crossversion/replay-diff.sh \
  --module targets/libs-extra \
  --dep github.com/digitorus/timestamp --old <old-version> --new <new-version> \
  --dep github.com/digitorus/pkcs7     --old <old-version> --new <new-version> \
  --func FuzzTimestampParseResponse \
  --out crossversion-report.md
```

`--dep`/`--old`/`--new` may each be repeated (same order) when the bump moves
more than one module together — e.g. `digitorus/timestamp`'s `go.mod` requires
a compatible `digitorus/pkcs7`; downgrading one without the other breaks
resolution rather than silently building an inconsistent pair. `--corpus-file`
may be repeated to inject an extra reproducer (e.g. one just found by the
rig) without committing it to the module first.

Exit code: `0` no flips · `1` flip(s) found (report written either way, so a
CI step can `|| true` and still attach it) · `2` usage/tooling error.

## Why this shape, not something heavier

- **No new judgment.** A subtest's PASS/FAIL is the target's OWN existing
  assertion (a crash, a deadline, or a reject/round-trip invariant already
  written into the `*_test.go` file). This script adds no opinion about what
  "correct" behavior is — it only asks whether changing one dependency
  version changed that pre-existing verdict for the same bytes. A flip can
  never be a false positive introduced by this script; at worst it inherits
  an already-unsound target invariant, which is a property of the target, not
  of this tool.
- **Whole-run failures count too.** An unrecovered panic in a goroutine spawned
  by `withinDeadline` (every `targets/*/` fuzz target routes through this)
  kills the entire `go test` process before any per-subtest PASS/FAIL line
  prints — so the crashing input never gets its own row in the per-input
  table. The script also compares each side's overall `go test` exit code and
  flags that mismatch directly (with a log tail), so this class of crash is
  never silently dropped for lack of a named subtest.
- **Scope, stated plainly:** this compares PASS/FAIL — accept/reject,
  crash/no-crash, deadline/no-deadline — per corpus entry. It does NOT compare
  decoded VALUES when both versions accept an input and the target carries no
  reject/round-trip invariant (e.g. `FuzzWebAuthnCredentialResponse`,
  `FuzzEtreeParse` accept most well-formed input by design) — that would need
  per-target structured-output capture that does not exist today. Targets
  already written as reject-only or round-trip invariants
  (`FuzzJWTParseIDToken`, `FuzzSAMLParseXMLResponse`,
  `FuzzTimestampParseRequest`, `FuzzGoXMLDSigReferenceBinding`) get full
  value-level protection for free, because their PASS/FAIL already encodes
  the value-level property.

## Validated against a real historical case

Demonstrated (not committed here — the reproducer bytes stay wherever the
private research that found them lives) against keyorix PR #1895
(`github.com/digitorus/pkcs7` `v0.0.0-20230713084857-e76b763bdc49` →
`v0.0.0-20260914070511-d678ea5ea03f`, `github.com/digitorus/timestamp`
`v0.0.0-20250524132541-c45532741eea` → `v0.0.0-20260914073129-b4b58b92aa51`):
a confirmed archived reproducer for the disclosed `ber.go` index-out-of-range
panic crashes the OLD pin's whole `go test` run and passes clean on the NEW
pin — `replay-diff.sh` reports this as a whole-run-signal flip (exit 1) with
the panic trace attached, exactly the "reproducers panic on the old pin,
clean on the new" verification #1895's own PR body did by hand.

## Not automatic (yet)

There is no hosted CI in this repo (see root `README.md`) and no Dependabot
config here either — the dependency bumps this exists for land in `keyorix`
main's `go.mod`/`go.sum`, not in this repo's `targets/*/go.mod` (those are
pinned by hand to match, per `scripts/check-shared-pins.sh`). Running this on
every real bump today is a manual step: when `check-shared-pins.sh` reports
drift for one of the six security-relevant libraries this track cares about
(`goxmldsig`, `crewjam/saml`, `golang-jwt`, `go-webauthn`, `digitorus/pkcs7`,
`x/crypto`), run `replay-diff.sh` with the old/new pair before bumping the
harness pin, and attach the report to the bump PR. Wiring this to run itself
on a Dependabot PR would need either a hosted CI job in the repo that opens
those bumps (`keyorix` itself, which does have CI) calling out to this repo,
or moving these harnesses' pins to also live in `keyorix`'s own Dependabot
scope — both are a call for a human to make, not a default this script should
assume.
