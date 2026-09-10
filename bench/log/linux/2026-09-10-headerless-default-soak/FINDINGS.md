# The headerless layout as the compile default: soak

Date: 2026-09-10 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.2
Tree `e5bae04` (post-#41: headerless is the compile default) · Crystal 1.21.0
`bench/soak.cr`, two arms, 14 minutes each, run in parallel.

## Why

The layout's soak evidence was `../2026-09-03-phase7-headerless-rss/` — a 5 h
run, but on the `simdgc-headerless` branch of 2026-09-03, when the layout was
opt-in and four releases of allocator work were still ahead of it. As of #41
it is what a plain `crystal build -Dgc_none` produces, so it needed a reading
on the tree that ships it. This is a short arm, not a replacement for the
weekly 5 h CI soak, which now builds this layout by default and gives the
first long reading on Monday.

| arm | build | verdict | RSS | errors | finalizers |
|---|---|---|---|---|---:|
| single thread | `-Dgc_none` | **PASSED** | 6 804 → 7 572 kB (+768 kB, max 7 724, ceiling +4 096) | 0 | 83 705 drained |
| EC4 + fiber churn | `-Dgc_none -Dpreview_mt -Dexecution_context`, `EC_PARALLELISM=4`, `--fiber-churn=512` | **PASSED** | 6 756 → 21 232 kB (+14 476 kB, max 90 516, ceiling +131 072) | 0 | 80 865 of 80 866 |

168 telemetry samples each. The single-thread arm is flat from the first
minute (7 648 → 7 724 kB across the whole run); the EC4 arm peaks at 90 MB
under 333 M queue-churn operations and drains to 21 MB, well inside the arm's
own ceiling. Zero errors and zero run-queue faults in both
(`queue slots seen: total=0 … faults=0`).

## Reading

Nothing here is new information about the layout — it is the same shape the
2026-09-03 5 h run reported (+3.2 MB against a 4 MB bound, flat from ~1 h) —
and that is the point: the flip did not move it. What this arm can and cannot
say: 14 minutes catches a leak with a slope, an error, or a finalizer that
stops draining; it cannot catch the step function the *header* arm showed at
5 h in the 2026-09-03 run (plateau at 12.4 MB, 8% over its bound). The weekly
soak is what decides that, and it now runs this layout without being asked.

One finalizer of 80 866 was still pending at exit in the EC4 arm, which is
the expected shape — the last allocation's finalizer is queued when the run
ends — not a drain failure.
