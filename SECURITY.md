# Security policy

## Scope

This policy covers vulnerabilities **in corobix itself** — the runner
(`fuzz-runner.sh`), the deploy scripts, the harness/target code under
`targets/`, and related tooling in this repo.

If you found a bug in one of the **third-party libraries corobix fuzzes**
(not in corobix's own code), please report it to that library's own
maintainer — that's who can actually fix it. If you're not sure where a
finding belongs, open a private report here anyway (see below) and we'll
help route it; see [`STATS.md`](STATS.md) for how this project's own
findings pipeline into upstream maintainers.

## Reporting a vulnerability

**Preferred:** use GitHub's private vulnerability reporting for this repo —
go to the [Security tab](../../security/advisories/new) and click
"Report a vulnerability". This creates a private draft advisory only the
maintainer can see; no public issue, no email needed.

**Fallback:** email andrey.beshkov@gmail.com with `[corobix security]` in
the subject line.

Please include:
- what's affected (which script/target) and a rough version/commit
- steps to reproduce, or a minimal repro input
- what you'd expect to happen vs. what actually happens

## What to expect

This is a solo-maintained project — there's no SLA and no bug bounty, but
reports are taken seriously and acknowledged on a best-effort basis
(typically within a few days). Confirmed issues follow coordinated
disclosure: fixed first, disclosed once a fix is available, with credit to
the reporter unless they ask otherwise.

## Supported versions

There are no released versions yet — `main` is the only supported branch.
