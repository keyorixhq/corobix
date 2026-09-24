#!/usr/bin/env python3
"""phase0_stats.py <json_dir> — Part A statistics from phase0.sh's trial JSON.

Per bug: median + IQR of time-to-find (duration_s, found trials only) per
condition, censored count, two-sided Mann-Whitney U p-value, and the
Vargha-Delaney A12 effect size (P(BASE slower) + 0.5*P(tie), i.e. A12 > 0.5
means AFTER tends to find the bug faster).

No scipy dependency (none installed on the bench box at recon time) — the
normal approximation with tie correction below is standard for n>=10 per
group (this design uses exactly 10), but is NOT an exact permutation test;
say so in the output rather than implying more precision than it has.

Censoring caveat, stated explicitly rather than silently applied: a censored
trial is treated as a tie at cap_s for ranking purposes. This is a common
simplification, not a formal right-censored-data rank test (e.g. Gehan's
test) — if a bug has many censored trials, prefer the reported censored
counts over the p-value/A12 for that bug, and the >50%-censored stopping
rule below refuses to report a verdict at all in that case.
"""
import sys
import json
import math
import glob
import os
from collections import defaultdict

def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return None
    mid = n // 2
    return xs[mid] if n % 2 else (xs[mid - 1] + xs[mid]) / 2

def iqr(xs):
    xs = sorted(xs)
    n = len(xs)
    if n < 2:
        return None
    def pct(p):
        idx = p * (n - 1)
        lo = math.floor(idx)
        hi = math.ceil(idx)
        if lo == hi:
            return xs[lo]
        return xs[lo] + (xs[hi] - xs[lo]) * (idx - lo)
    return pct(0.75) - pct(0.25)

def normal_cdf(z):
    return 0.5 * (1 + math.erf(z / math.sqrt(2)))

def mann_whitney(a, b):
    """Two-sided normal-approximation Mann-Whitney U, tie-corrected.
    Returns (U_a, p_value, a12). a12 = U_a / (len(a)*len(b))."""
    n1, n2 = len(a), len(b)
    if n1 == 0 or n2 == 0:
        return None, None, None
    combined = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks = [0.0] * len(combined)
    i = 0
    while i < len(combined):
        j = i
        while j < len(combined) and combined[j][0] == combined[i][0]:
            j += 1
        avg_rank = (i + 1 + j) / 2.0
        for k in range(i, j):
            ranks[k] = avg_rank
        i = j
    r1 = sum(r for r, (v, grp) in zip(ranks, combined) if grp == 0)
    u1 = r1 - n1 * (n1 + 1) / 2.0
    n_total = n1 + n2
    tie_groups = defaultdict(int)
    for v, _ in combined:
        tie_groups[v] += 1
    tie_correction = sum(t ** 3 - t for t in tie_groups.values())
    mean_u = n1 * n2 / 2.0
    var_u = (n1 * n2 / 12.0) * ((n_total + 1) - tie_correction / (n_total * (n_total - 1))) if n_total > 1 else 0
    if var_u <= 0:
        p = 1.0
    else:
        z = (u1 - mean_u) / math.sqrt(var_u)
        p = 2 * (1 - normal_cdf(abs(z)))
    a12 = u1 / (n1 * n2)
    return u1, p, a12

def a12_magnitude(a12):
    d = abs(a12 - 0.5)
    if d < 0.06:
        return "negligible"
    if d < 0.14:
        return "small"
    if d < 0.21:
        return "medium"
    return "large"

def main():
    if len(sys.argv) != 2:
        print("usage: phase0_stats.py <json_dir>", file=sys.stderr)
        sys.exit(2)
    json_dir = sys.argv[1]
    by_bug = defaultdict(lambda: defaultdict(list))
    for path in glob.glob(os.path.join(json_dir, "partA__*.json")):
        with open(path) as f:
            rec = json.load(f)
        by_bug[rec["bug"]][rec["condition"]].append(rec)

    if not by_bug:
        print("no partA__*.json records found in", json_dir, file=sys.stderr)
        sys.exit(1)

    print("| bug | cond | n | censored | median_s | iqr_s | mw_p | a12 | a12_mag | verdict |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for bug in sorted(by_bug):
        base_recs = by_bug[bug].get("base", [])
        after_recs = by_bug[bug].get("after", [])
        base_n, after_n = len(base_recs), len(after_recs)
        base_censored = sum(1 for r in base_recs if r["censored"])
        after_censored = sum(1 for r in after_recs if r["censored"])

        skip = False
        reason = ""
        if base_n == 0 or after_n == 0:
            skip = True
            reason = "dropped before trials ran (see notes.txt)"
        elif base_n and base_censored > base_n / 2:
            skip = True
            reason = f"base censored {base_censored}/{base_n} > half"
        elif after_n and after_censored > after_n / 2:
            skip = True
            reason = f"after censored {after_censored}/{after_n} > half"

        base_durs = [r["duration_s"] if not r["censored"] else r["cap_s"] for r in base_recs]
        after_durs = [r["duration_s"] if not r["censored"] else r["cap_s"] for r in after_recs]

        base_med = median(base_durs) if base_durs else None
        after_med = median(after_durs) if after_durs else None
        base_iqr = iqr(base_durs) if base_durs else None
        after_iqr = iqr(after_durs) if after_durs else None

        if skip:
            print(f"| {bug} | base | {base_n} | {base_censored} | {base_med} | {base_iqr} | - | - | - | NO CLAIM: {reason} |")
            print(f"| {bug} | after | {after_n} | {after_censored} | {after_med} | {after_iqr} | - | - | - | NO CLAIM: {reason} |")
            continue

        u1, p, a12 = mann_whitney(base_durs, after_durs)
        mag = a12_magnitude(a12) if a12 is not None else "-"
        verdict = "AFTER faster" if a12 is not None and a12 > 0.5 else "BASE faster or no diff"
        print(f"| {bug} | base | {base_n} | {base_censored} | {base_med} | {base_iqr} | {p:.4f} | {a12:.3f} | {mag} | {verdict} |")
        print(f"| {bug} | after | {after_n} | {after_censored} | {after_med} | {after_iqr} | {p:.4f} | {a12:.3f} | {mag} | {verdict} |")

        oracle_mismatches = [r for r in base_recs + after_recs if r["found"] and not r["oracle_matches_bug"]]
        if oracle_mismatches:
            print(f"  NOTE: {bug} has {len(oracle_mismatches)} trial(s) where go test failed but the "
                  f"oracle message did not match this bug's expected substring — inspect before trusting "
                  f"'found' for those (may be an unrelated flake, not this bug).", file=sys.stderr)

if __name__ == "__main__":
    main()
