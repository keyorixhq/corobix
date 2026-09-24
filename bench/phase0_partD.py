#!/usr/bin/env python3
"""phase0_partD.py — rig-history extraction from the fuzz-archive bundle.

Runs on the Mac, no box needed. Two inputs:
  1. ~/proj/fuzz-archive/2026-09-21-vcd-decommission/ (the keyorix-fuzz rig's
     final-corpus + per-cycle-log tarballs, captured at decommission time)
  2. ~/proj/fuzz-archive/fuzzing-catches-ledger.md (the running catch ledger)

Honesty note, checked directly against the actual archive contents rather
than assumed from its directory name: this bundle is a DECOMMISSION SNAPSHOT
of the rig's final state plus ONE night's worth of dated per-cycle logs
(home/andrei/night/{logs,phase2}/, spanning roughly 2026-09-20 16:00Z through
2026-09-21 ~15:26Z per the janitor2.log free-space samples) -- NOT a rolling
7-day log. "Per-target new-interesting over the last 7 days" as asked cannot
be honestly produced from this bundle alone; this script reports what the
bundle actually contains (final corpus size per target + that one night's
per-cycle new-interesting) and says so explicitly rather than mislabeling a
~23h window as 7 days. A true 7-day figure would need the other dated
fuzz-archive snapshots (2026-09-11/12/13/19/20) cross-referenced by target,
which this script does not attempt.
"""
import sys
import re
import tarfile
import json
from pathlib import Path
from collections import defaultdict

ARCHIVE_DIR = Path.home() / "proj/fuzz-archive/2026-09-21-vcd-decommission"
LEDGER_PATH = Path.home() / "proj/fuzz-archive/fuzzing-catches-ledger.md"

FUZZ_LINE = re.compile(
    r"fuzz: elapsed: (?P<elapsed>[0-9hms]+), execs: (?P<execs>\d+) \(\d+/sec\), "
    r"new interesting: (?P<new_int>\d+) \(total: (?P<total>\d+)\)"
)


def dur_to_secs(s):
    if s.isdigit():
        return int(s)
    total = 0
    for n, unit in re.findall(r"(\d+)([hms])", s):
        total += int(n) * {"h": 3600, "m": 60, "s": 1}[unit]
    return total


def final_corpus_sizes(testdata_tgz):
    """Count seed files per Fuzz target from the testdata-fuzz tarball.
    Each corpus entry appears listed twice in this tarball (confirmed by
    inspection -- tar stores the same path from two different snapshot
    passes); dedupe by path before counting."""
    counts = defaultdict(set)
    with tarfile.open(testdata_tgz) as tf:
        for member in tf.getmembers():
            if not member.isfile():
                continue
            m = re.search(r"testdata/fuzz/(Fuzz\w+)/([0-9a-f]+)$", member.name)
            if m:
                target, seed_hash = m.groups()
                counts[target].add(seed_hash)
    return {target: len(seeds) for target, seeds in counts.items()}


def per_cycle_stats(logs_tgz):
    """Parse every dated per-cycle log for its final progress line -> cumulative
    new_interesting and elapsed_s for that cycle. Returns {target: [cycles]}."""
    by_target = defaultdict(list)
    with tarfile.open(logs_tgz) as tf:
        for member in tf.getmembers():
            if not member.isfile() or not member.name.endswith(".log"):
                continue
            base = Path(member.name).name
            m = re.match(r"^[A-Z]\d-(Fuzz\w+)-(\d{4})\.log$", base)
            if not m:
                continue  # janitor/phase/runA support logs, not a fuzz cycle
            target, hhmm = m.groups()
            content = tf.extractfile(member).read().decode("utf-8", "replace")
            lines = FUZZ_LINE.findall(content)
            if not lines:
                continue
            last = lines[-1]
            by_target[target].append({
                "cycle_hhmm": hhmm,
                "elapsed_s": dur_to_secs(last[0]),
                "execs": int(last[1]),
                "new_interesting": int(last[2]),
                "total_corpus_at_cycle_end": int(last[3]),
            })
    return by_target


def ledger_catch_counts(ledger_path):
    """Severity column -> count, from the ledger's markdown table. Severity
    cells are free text ('HIGH upstream', 'Medium (SSRF...)', etc.) -- bucket
    by the first ALL-CAPS/Capitalized severity word found, report an
    'unparsed' bucket rather than silently dropping rows that don't match."""
    text = ledger_path.read_text()
    rows = [l for l in text.splitlines() if l.startswith("|") and "---" not in l]
    if not rows:
        return {}
    # column order fixed by the ledger's own header: Date | Target | Component | Severity | ...
    counts = defaultdict(int)
    unparsed = 0
    for row in rows[1:]:  # skip header row
        cells = [c.strip() for c in row.split("|")]
        if len(cells) < 5:
            continue
        severity_cell = cells[4]
        m = re.search(r"\b(CRITICAL|HIGH|MEDIUM|LOW|INFO|NONE)\b", severity_cell, re.IGNORECASE)
        if m:
            counts[m.group(1).upper()] += 1
        else:
            unparsed += 1
    if unparsed:
        counts["UNPARSED"] = unparsed
    return dict(counts)


def main():
    out = {
        "_honesty_note": (
            "final_corpus_sizes and per_cycle_stats come from the 2026-09-21 "
            "decommission bundle, which covers ONE night (~2026-09-20 16:00Z "
            "to ~2026-09-21 15:26Z per janitor2.log), not a rolling 7 days. "
            "See this script's module docstring."
        ),
    }
    testdata_tgz = ARCHIVE_DIR / "vcd-keyorix-fuzz.testdata-fuzz.tgz"
    logs_tgz = ARCHIVE_DIR / "vcd-keyorix-fuzz.logs.tgz"

    if testdata_tgz.exists():
        out["final_corpus_sizes"] = final_corpus_sizes(testdata_tgz)
    else:
        out["final_corpus_sizes"] = None
        sys.stderr.write(f"missing {testdata_tgz}\n")

    if logs_tgz.exists():
        cycles = per_cycle_stats(logs_tgz)
        out["per_target_cycles_one_night"] = cycles
        out["cycle_length_s_by_target"] = {
            t: sorted(c["elapsed_s"] for c in v) for t, v in cycles.items()
        }
        out["new_interesting_sum_one_night_by_target"] = {
            t: sum(c["new_interesting"] for c in v) for t, v in cycles.items()
        }
    else:
        out["per_target_cycles_one_night"] = None
        sys.stderr.write(f"missing {logs_tgz}\n")

    if LEDGER_PATH.exists():
        out["ledger_catch_counts_by_severity"] = ledger_catch_counts(LEDGER_PATH)
    else:
        out["ledger_catch_counts_by_severity"] = None
        sys.stderr.write(f"missing {LEDGER_PATH}\n")

    print(json.dumps(out, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
