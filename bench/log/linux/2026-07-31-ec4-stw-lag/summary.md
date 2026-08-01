# EC4 STW stack LAG (512 KiB)

Host: WSL2 · Crystal 1.21.0 · `wrk -c 100 -d 20` `/json` · TLAB off · median-of-5 same-session A/B

| Build | trials req/s | median |
|-------|-------------:|-------:|
| LAG 512 KiB | 29892, 17761, 32464, 30673, 30009 | **30009** |
| classic stw_full (guard→bottom) | 19218, 12330, 22537, 2551, 15676 | **15676** |

LAG / stw_full ≈ **1.91×**. Soak EC4 default 30×8s: **0/30** fail.

Earlier baseline session `2026-07-31-100844` gcry EC4 med **16426** (~23% Boehm EC4).
LAG same-host Boehm EC4 ~80k → ~37% Boehm if 30k holds (do not write PERF.md — EC1-only).

Change: `scan_all_fiber_roots` multi-mutator uses SP−red_zone when present,
else `stack_top − 512KiB` (not full guard). `scan_other_thread_stacks` unchanged.

