# `make soak` and `make soak-smoke` must fail on a workload that leaks

**Date:** 2026-09-21 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `f136bb1` (0.26.3) · `python3 bench/gate_arm_census.py`

The soak's only gate is an absolute RSS ceiling over the warm-up plateau
(+4096 kB, measured on both platforms) plus "no crash". The ceiling had
only ever been seen to hold: nothing showed that a workload which does
grow would cross it, and a ceiling read against a start of 0 once passed
on Darwin by measuring nothing.

## What changed

`bench/soak.cr --leak-kb-per-s=N`: a fiber retains N kB of fresh strings
per second in an array it never shifts. Everything else in the workload
is unchanged, so the arm differs from shipped by the leak alone. Both
targets run it for 10 s at 1024 kB/s under `!`, then `grep -q "# result:
FAIL: RSS grew"` on its telemetry — the arm must fail, and must fail on
the ceiling rather than on a crash or a refused flag. Inlined in both
recipes rather than a shared target, because the census reads recipes
that name a harness and would not follow `$(MAKE)`.

## Measured

| arm | start → end RSS | verdict |
|---|---|---|
| shipped smoke, 10 s | 7420 → 8064 kB (+644) | PASS, ceiling +4096 |
| `--leak-kb-per-s=1024`, 10 s | 7264 → 19708 kB (**+12444**) | FAIL `RSS grew` — required |
| same, second run | 7436 → 19960 kB (+12524) | FAIL — required |

`make soak-smoke` 22 s all in.

## Darwin correction (2026-09-22)

The first CI run on `macos-latest` landed the arm at **+4048 kB against
+4096** and it passed, so `!` failed the job (run `35696157334`). Two
things the Linux measurement hid: the leak was a fixed slice per 10 ms
tick and the Darwin timer delivered ~60 ticks a second (heap +6.2 MB in
10 s, not 10), and Darwin's RSS followed the heap at ~0.65×. The leak is
topped up to `elapsed × rate` now, so retained bytes are a function of
wall time, and the rate is 2 MB/s: **+26.3 MB** here (7440 → 33780 kB),
and on the Darwin runner **+26.8 MB** (4416 → 31216 kB, run
`35698178414`) — the same magnitude, so the 0.65× was the timer's
shortfall showing through the RSS and not a Darwin accounting property.

## Census

```
harness-driven gates:              100
red direction constructed per run: 77
red direction established by hand: 23
```

**100 / 75 / 25 → 100 / 77 / 23.** `soak` and `soak-smoke`, recipe 1
each. Still owed an arm: `compiler-gc-contract`, `finalizer-complex`,
`oom-test`(+short), `thread-storm`(+short).
