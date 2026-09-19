# Fuzz benchmark — dashdiag-fuzz (20260919T070830Z)

Role: dashdiag   Dry run: no

## Throughput

| target | parallel | execs/s | execs/s/core | new_interesting | total_corpus | peak_rss_kb | build_s |
|---|---|---|---|---|---|---|---|
| FuzzParseSystemdTime | 7 | 24516 | 3502 | 179 | 186 | 941948 | 31 |

## Parallel scaling

| target | parallel | execs/s | execs/s/worker |
|---|---|---|---|

## Time-to-find (median over reps, seconds; cap = 3600 s)

| case | reps found | median seconds |
|---|---|---|
| case_c__FuzzTimestampParseResponse_pkcs7 | 0/5 | 14 |

## Notes

- runner paused: production fuzz services were confirmed inactive before benchmarking (see hw.txt)
- PG DSN available: no
- dashdiag collector chosen: FuzzParseSystemdTime (internal/collectors/fuzz_time_parsers_linux_test.go) — pure string parser, no host syscalls, fast+stable
