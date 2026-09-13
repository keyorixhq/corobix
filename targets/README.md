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
| `libs-extra/` (`keyorix-libs-extra-fuzz`) | vcd-dashdiag · `libs-extra-fuzz.service` | crewjam/saml `xmlenc`, mattermost `xml-roundtrip-validator`, digitorus/timestamp, JWT signature-bypass rejection template |

## Detection layers per target
- panics / crashes — native `go test -fuzz`
- OOM / memory amplification — rig cgroup `MemoryMax` (`MemorySwapMax=0`)
- CPU-time / algorithmic-complexity DoS — per-input `withinDeadline` (2s)
- correctness — round-trip / re-parse / signature-bypass **rejection** invariants where a
  *sound* one exists (see per-target comments). Note: for XML, assert "re-parse of own
  output succeeds," never byte-idempotence — XML normalization (e.g. the `&#xd;` CR
  reference) legitimately changes on round-trip and is not a bug.

## Not in this repo (by design)
- `fuzz.conf` — per-rig config (ntfy URL, corpus remote, `EXCLUDE`, durations): box-local, gitignored.
- `testdata/fuzz/` — generated corpus + crash reproducers: backed up to the private `fuzz-corpus` repo.

## Deploying a change
Edit here → PR → merge → copy the module to its rig (`scp` + atomic `mv`, same as the
runner). Rigs currently run standalone copies; they could later clone this repo and
`git`-pull, matching how the keyorix rig auto-pulls its targets.
