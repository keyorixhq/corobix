# Fuzz benchmark — keyorix-fuzz (20260919T005302Z)

Role: keyorix   Dry run: no

## Throughput

| target | parallel | execs/s | execs/s/core | new_interesting | total_corpus | peak_rss_kb | build_s |
|---|---|---|---|---|---|---|---|
| FuzzPATRestrictionAllows | 7 | 5345 | 763 | 34 | 39 | 2067260 | 119 |
| FuzzAEADTamperRoundTrip | 7 | 8738 | 1248 | 12 | 16 | 626560 | 9 |
| FuzzKEKRotationCrashConsistency | 7 | 2 | 0 | 9 | 20 | 627200 | 8 |
| FuzzStorageBackendDifferential | 7 | 503 | 71 | 753 | 755 | 898092 | 19 |

## Parallel scaling

| target | parallel | execs/s | execs/s/worker |
|---|---|---|---|
| FuzzPATRestrictionAllows | 1 | 893 | 893 |
| FuzzPATRestrictionAllows | 2 | 1819 | 909 |
| FuzzPATRestrictionAllows | 4 | 3695 | 923 |
| FuzzPATRestrictionAllows | 7 | 5371 | 767 |
| FuzzAEADTamperRoundTrip | 1 | 1415 | 1415 |
| FuzzAEADTamperRoundTrip | 2 | 2855 | 1427 |
| FuzzAEADTamperRoundTrip | 4 | 5948 | 1487 |
| FuzzAEADTamperRoundTrip | 7 | 8717 | 1245 |

## Time-to-find (median over reps, seconds; cap = 3600 s)

| case | reps found | median seconds |
|---|---|---|
| case_a__FuzzParseResponse_pr1889 | 0/3 | 3600 |

## Notes

- runner paused: production fuzz services were confirmed inactive before benchmarking (see hw.txt)
- PG DSN available: yes
- ttf: case_b__FuzzDEKSweepCrashConsistency_pr1918 DOES NOT COMPILE AFTER REVERT — skipping (the fix's own regression test likely calls a symbol the fix itself introduced; see raw/ttf-case_b__FuzzDEKSweepCrashConsistency_pr1918-postrevert-build.log). Not mechanically revertible by file-level revert; needs a hand-authored partial patch if this case matters.
