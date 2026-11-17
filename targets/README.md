# targets/ — third-party fuzz target harnesses

Standalone Go modules that fuzz the third-party libraries keyorix/dashdiag hand
**untrusted** bytes and that upstream does **not** fuzz (OpenSSF Scorecard 0). The
universal runner (`../fuzz-runner.sh`) discovers and drives the `Fuzz*` targets in
whichever module a rig points `MODULE_DIR` at.

Runner = *how* to fuzz (`../fuzz-runner.sh`); these = *what* to fuzz. keyorix's OWN
internal fuzz targets live in the **keyorix repo** (`internal/**/*_fuzz_test.go`),
beside the code they exercise — they can't live here (internal packages).

| module | rig / service | targets |
|---|---|---|
| `libs/` (`keyorix-libs-fuzz`) | pve01 · `libsfuzz.service` | go-webauthn credential + `x/encoding/asn1`, golang-jwt id_token parse, crewjam/saml `ParseXMLResponse`, beevik/etree |
| `libs-extra/` (`keyorix-libs-extra-fuzz`) | vcd-dashdiag · `libs-extra-fuzz.service` | crewjam/saml `xmlenc`, mattermost `xml-roundtrip-validator`, digitorus/timestamp, JWT signature-bypass rejection template, russellhaering/goxmldsig reference-binding bypass invariant (CVE-2026-33487 property, see the target's own doc comment) |

## Detection layers per target
- panics / crashes — native `go test -fuzz`
- OOM / memory amplification — rig cgroup `MemoryMax` (`MemorySwapMax=0`)
- CPU-time / algorithmic-complexity DoS — per-input `withinDeadline` (2s)
- correctness — round-trip / re-parse / signature-bypass **rejection** invariants where a
  *sound* one exists (see per-target comments). Note: for XML, assert "re-parse of own
  output succeeds," never byte-idempotence — XML normalization (e.g. the `&#xd;` CR
  reference) legitimately changes on round-trip and is not a bug.

## Per-input deadline (enforced)

Native `go test -fuzz` has **no per-input timeout**, so a CPU-time / algorithmic-
complexity DoS input only drags throughput — it is never flagged as a crasher. Every
target therefore routes its `f.Fuzz` body through the shared `withinDeadline` helper
(goroutine + `select` on a fixed **2s** budget). Keep any `t.Fatal` assertions
*outside* the guarded closure — `t.Fatal` only fires on the test's own goroutine, not
the child goroutine `withinDeadline` runs the work in.

`scripts/require-deadline.sh` makes this enforceable so an unguarded target cannot
land: it checks that every `func Fuzz*` calls `withinDeadline`, and that each module
keeps the canonical helper with the uniform 2s budget (the modules are separate, so
the helper is copied — this guards against drift). Pure bash/awk/grep; no Go toolchain
needed, so it runs on a bare rig or in the local gate.

```sh
scripts/require-deadline.sh          # lint every module under targets/
bats tests/require-deadline.bats     # its own unit tests
```

A target that genuinely cannot use the deadline (e.g. a replay-only smoke target that
does no parsing) must carry a `//fuzzlint:no-deadline: <reason>` line inside the
function to document the exception.
## Freeze-aware deadline

`withinDeadline` waits through `Wait` (`targets/*/stall_test.go`, generated from
`shared/stall.go.body` by `scripts/sync-stall.sh`): a process-wide monitor records stretches
where the whole process was not scheduled (GC, swap, cgroup throttling, host contention on
the shared rigs), and a deadline miss that overlaps a freeze gets one more full budget
before it is reported. Only a call still running after that fails, so a frozen box no
longer produces "possible algorithmic-complexity DoS" findings that never reproduce.
`FUZZ_STALL_LOG=<file>` appends one line per detected freeze (the runner sets it per slice
and summarises it in `stalls.tsv`). `scripts/sync-stall.sh --check [FILE...]` fails when any
copy drifts from the canonical body; pass the keyorix/dashdiag `internal/fuzzutil/stall.go`
paths to check those too. Canonical logic: keyorixhq/keyorix `internal/fuzzutil/stall.go`.

## Not in this repo (by design)
- `fuzz.conf` — per-rig config (ntfy URL, corpus remote, `EXCLUDE`, durations): box-local, gitignored.
- `testdata/fuzz/` — generated corpus + crash reproducers: backed up to the private `fuzz-corpus` repo.

## Deploying a change
Edit here → PR → merge → copy the module to its rig (`scp` + atomic `mv`, same as the
runner). Rigs currently run standalone copies; they could later clone this repo and
`git`-pull, matching how the keyorix rig auto-pulls its targets.
