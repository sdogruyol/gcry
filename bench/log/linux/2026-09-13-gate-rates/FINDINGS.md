# Rates for the gates that reddened CI and never reddened here

Date: 2026-09-13/14 (overnight) · host: AMD Ryzen AI 9 465, Linux 7.2.4, 8 cores
· tree: `5e1c101` · under load: an 8 h soak and two `chunk_list_drift` children
ran throughout

Three gates went red on CI this week on trees that could not have caused it, and
each looked like a defect until a re-run passed. A rate is what separates "this
gate is flaky" from "that runner is", so they ran in a loop overnight:

| gate | runs | failures |
|---|---|---|
| `poison-holders` | 120 | **0** |
| `mark-clear-index` | 40 | **0** |
| `chunk-list-drift` | 12 | **0** |
| `counter-loss` | 12 | **0** |
| the five aarch64 retention specs | 80 | **0** |
| `thread-churn-uaf` | 6 | **2** |

`poison-holders` is the one that matters most: it went red three times in two
days on the x86_64 runner, always with the report dying inside its own first
walk, and 120 runs here produce nothing. That asymmetry is what the 256 KiB
alternate signal stack explains — Crystal's 8 KiB left 4 720 bytes for the
report, and the runner's slightly different prologue crossed the line.

The five retention specs that failed *together* on `test (aarch64 native)` on
two documentation-only commits pass 80 of 80 here. Same conclusion, same shape:
host, not collector. The candidate to check when it recurs is the runner's page
size, since every one of those specs reasons about chunk residency.

`thread-churn-uaf`'s 2 of 6 is not flakiness — it is a sighting, and it has its
own log: `bench/log/linux/2026-09-13-released-range-report/FINDINGS.md`. Its
guarded arm faulted 3.8 MB above the heap span and the crash report excluded the
mechanism by name, which is now fixed. The load these loops ran under is
probably why it showed here and not in the daytime runs.
