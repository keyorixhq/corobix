# Findings

*Auto-generated from an internal findings registry by `registry/gen_public_stats.py` — don't hand-edit. Last regenerated 2026-11-18.*

As of 2026-11-18, continuous fuzzing runs built on this runner have produced **62 confirmed findings** across **34 open-source Go dependencies** — crypto/auth libraries, cloud SDKs, database drivers, parsers, and more.

**Scope note:** these numbers cover fuzzing of third-party/open-source dependencies only. Findings inside first-party product code are tracked separately in a private registry and are not included here.

**Disclosure policy:** every finding here is handled under coordinated disclosure with the upstream maintainer — reported privately first, named individually only once a fix has shipped and the maintainer's own advisory is public (see "Publicly disclosed" below for those). Aggregate counts and categories are safe to publish for everything else; specific reproduction details, PoCs and affected-version ranges are withheld until each embargo lifts. This page is regenerated monthly, so entries move from the aggregate counts into the named list as embargoes expire and fixes land — it is not a static snapshot.

## By severity

| Severity | Count |
|---|---|
| High | 2 |
| Moderate | 6 |
| Low | 49 |
| Informational | 5 |

## By category

| Category | Count |
|---|---|
| Differential / logic / contract mismatches | 29 |
| Crashes & panics | 19 |
| Resource exhaustion / DoS | 12 |
| Injection / info-leak | 2 |

## Dependencies covered so far

34 open-source Go modules, spanning crypto/auth, cloud SDKs, database drivers, and parsers/codecs:

| Module | Findings |
|---|---|
| `github.com/aws/aws-sdk-go-v2` | 1 |
| `github.com/aws/aws-sdk-go-v2 and github.com/Azure/azure-sdk-for-go/sdk/azcore` | 1 |
| `github.com/Azure/azure-sdk-for-go/sdk/azcore` | 2 |
| `github.com/Azure/azure-sdk-for-go/sdk/security/keyvault/internal` | 1 |
| `github.com/boombuler/barcode` | 1 |
| `github.com/charmbracelet/x/ansi` | 1 |
| `github.com/charmbracelet/x/cellbuf` | 4 |
| `github.com/crewjam/saml` | 4 |
| `github.com/digitorus/pkcs7` | 3 |
| `github.com/digitorus/timestamp` | 1 |
| `github.com/fxamacker/cbor/v2` | 1 |
| `github.com/go-sql-driver/mysql` | 5 |
| `github.com/go-webauthn/webauthn` | 1 |
| `github.com/google/go-tpm` | 2 |
| `github.com/google/jsonschema-go` | 1 |
| `github.com/jackc/pgx/v5` | 1 |
| `github.com/mattermost/xml-roundtrip-validator` | 1 |
| `github.com/modelcontextprotocol/go-sdk` | 1 |
| `github.com/pquerna/otp` | 2 |
| `github.com/prometheus-community/pro-bing` | 1 |
| `github.com/redis/go-redis/v9` | 3 |
| `github.com/russellhaering/goxmldsig` | 3 |
| `github.com/santhosh-tekuri/jsonschema/v6` | 2 |
| `github.com/shirou/gopsutil/v3` | 1 |
| `github.com/subosito/gotenv` | 2 |
| `github.com/wneessen/go-mail` | 1 |
| `github.com/xdg-go/stringprep` | 1 |
| `github.com/xo/terminfo` | 4 |
| `github.com/yosida95/uritemplate/v3` | 4 |
| `github.com/youmark/pkcs8` | 1 |
| `go.yaml.in/yaml/v2, go.yaml.in/yaml/v3 (also reproduces on the pre-fork gopkg.in/yaml.v3)` | 1 |
| `go.yaml.in/yaml/v4` | 1 |
| `gopkg.in/yaml.v3` | 2 |
| `std/mime/quotedprintable` | 1 |

## Publicly disclosed (sample)

Most findings are still inside a responsible-disclosure window with the upstream maintainer and aren't named individually until a fix has shipped and the advisory is public. These already are:

- **github.com/digitorus/pkcs7** — digitorus/pkcs7 Defect 1: BER memory-exhaustion DoS — [KFZ-2026-001](https://github.com/digitorus/pkcs7/security/advisories/GHSA-3xqc-rpq8-wgp9)
- **github.com/digitorus/pkcs7** — digitorus/pkcs7 Defect 2: BER out-of-bounds panic — [KFZ-2026-002](https://github.com/digitorus/pkcs7/security/advisories/GHSA-73j8-gqc5-c98v)
- **github.com/digitorus/pkcs7** — digitorus/pkcs7 CBC unpad: panic on oversized pad length, pad length 0 accepted, padding oracle — [KFZ-2026-003](https://github.com/digitorus/pkcs7/security/advisories/GHSA-cj86-7jch-72f4)
- **github.com/jackc/pgx/v5** — jackc/pgx v5: Rows.Values() panics when DataRow has fewer values than RowDescription — [KFZ-2026-004](https://github.com/jackc/pgx/security/advisories/GHSA-w9rp-vfrh-q8vv)

