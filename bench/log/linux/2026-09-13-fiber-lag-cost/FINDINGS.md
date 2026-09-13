# What the parked-fiber lag actually reads — and two wrong readings on the way

Date: 2026-09-13/14 (overnight) · host: AMD Ryzen AI 9 465, Linux 7.2.4 ·
tree: `89529cb` · harness `bench/fiber_lag_cost.cr`

The largest open pause item says 8.4 ms of a 9.2 ms p50 pause at Kemal `-c100`
is `roots_fibers_ns`, and proposes scanning a fully parked fiber from its own SP
instead of from 256 KiB below its saved `stack_top`. That is a root-scan change,
where being wrong is a use-after-free days later, so the payoff wanted measuring
first. It took three attempts to measure it, and the two failures are the
interesting part.

## The measurement

`fiber_lag_window_bytes` is the nominal window — the distance between a parked
fiber's saved `stack_top` and where its scan starts — and
`low_water_skipped_bytes` is what the pagemap low-water probe removes from it.
256 fibers on a `Fiber::ExecutionContext::Parallel`, 10 collections:

| arm | nominal window | removed by the skip | **actually read** | probe found nothing to skip |
|---|---|---|---|---|
| parked on untouched stacks | 67 072 KiB | 67 858 KiB | **≈ 0** | 0 |
| 512 KiB touched, then parked shallow | 67 072 KiB | 2 470 KiB | **64 602 KiB** | 2 560 |

Per collection, per parked fiber: **nothing** in the first arm, **246.6 KiB** in
the second. So the lag is free when the stack below the parked frames was never
faulted, and costs essentially the whole window when it was — and the second arm
is not exotic: one deep call followed by parking shallow is enough, on a single
fiber, within its own lifetime. That is the roadmap's "pooled stacks lose it over
time" without needing a pool or any time.

The proposal's payoff is therefore the deep case, and there it is real: ~64.6 MB
of reads per collection at 256 parked fibers, linear in the count (17.5 / 33.5 /
65.5 / 129.5 MB nominal at 64 / 128 / 256 / 512).

## The first wrong reading: the nominal window is not what is read

`fiber_lag_window_bytes` alone said 65.5 MB per collection and that was reported
as the payoff. It is the *window*, not the reads: on untouched stacks the
low-water probe moves the scan start above `stack_top` and the window is never
touched. Removing the lag there would save nothing at all.

## The second: a counter that forgets

Holding the fiber count and varying collections showed **266 low-water skips
whether the run did 1 collection or 20**, while parked scans went 262 → 5 240.
That reads as a skip that fires once per fiber and never again, and it was
written up that way. It is wrong: `@low_water_skips` and
`@low_water_skipped_bytes` are **reset every collection** in `collect.cr`'s
per-collection reset block, so a read after N collections reports the last one.
Summed per collection, the skip fires on essentially every parked scan.

Two counters were added while chasing that, and they are what made the third
attempt conclusive rather than another guess: `low_water_misses` (the probe ran
and found a faulted page at or below the lag floor — 0 in the shallow arm, 2 560
in the deep one, exactly 256 fibers x 10 collections) and `low_water_unprobed`
(the lag floor sat above the stack's high end — 0 in both, which is what
eliminated the last alternative).

## What is still open

The fix itself. A fully parked fiber's `stack_top` is trustworthy *if* it is
genuinely parked, and that predicate is the difficulty — `Fiber#running?` only
approximates it, which is why the lag exists. The alternative the item already
names, a per-fiber high-water mark written at swap time, would make the deep arm
as cheap as the shallow one without needing the predicate at all, and this
harness is how either would be measured.
