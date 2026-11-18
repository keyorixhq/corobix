# Findings

*Auto-generated from an internal findings registry by `registry/gen_public_stats.py` — don't hand-edit. Last regenerated 2026-11-18.*

As of 2026-11-18, continuous fuzzing runs built on this runner have produced **62 confirmed findings** across **34 open-source Go dependencies** — crypto/auth libraries, cloud SDKs, database drivers, parsers, and more.

**Scope note:** these numbers cover fuzzing of third-party/open-source dependencies only. Findings inside first-party product code are tracked separately in a private registry and are not included here.

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

## Publicly disclosed (sample)

Most findings are still inside a responsible-disclosure window with the upstream maintainer and aren't named individually until a fix has shipped and the advisory is public. These already are:

- **github.com/digitorus/pkcs7** — digitorus/pkcs7 Defect 1: BER memory-exhaustion DoS — [KFZ-2026-001](https://github.com/digitorus/pkcs7/security/advisories/GHSA-3xqc-rpq8-wgp9)
- **github.com/digitorus/pkcs7** — digitorus/pkcs7 Defect 2: BER out-of-bounds panic — [KFZ-2026-002](https://github.com/digitorus/pkcs7/security/advisories/GHSA-73j8-gqc5-c98v)
- **github.com/digitorus/pkcs7** — digitorus/pkcs7 CBC unpad: panic on oversized pad length, pad length 0 accepted, padding oracle — [KFZ-2026-003](https://github.com/digitorus/pkcs7/security/advisories/GHSA-cj86-7jch-72f4)
- **github.com/jackc/pgx/v5** — jackc/pgx v5: Rows.Values() panics when DataRow has fewer values than RowDescription — [KFZ-2026-004](https://github.com/jackc/pgx/security/advisories/GHSA-w9rp-vfrh-q8vv)

