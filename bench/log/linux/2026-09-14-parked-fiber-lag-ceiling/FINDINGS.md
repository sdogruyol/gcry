# The parked-fiber lag: its ceiling, measured, and why the fix cannot be earned

Date: 2026-09-14 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree: `3dc1329`
Harness: `bench/lag_width_ab.sh`, `bench/fiber_lag_cost.cr`

`ROADMAP.md` carried, since 2026-09-08:

> **The EC4 pause is the parked-fiber lag scan, and it grows with uptime.**
> A fully parked fiber (wait queue, no owning thread) has a trustworthy SP and
> can be scanned from it as on EC1; only fibers in transit need the lag.

Three questions, in the order that decides the work: what does the lag cost on
the workload that motivated it, what is the most any fix could return, and is
the predicate the fix needs even available.

## 1. The phase is what the item says it is

With `GCRY_ROOT_PHASE_TIMING=1` on Kemal `/json`, `-c100`, EC parallelism 4:
`last_roots_fibers_ns` is **80.6%** of the pause (3.95 ms of 4.90 ms per
collection, 165 collections). The item's premise holds on this host.

## 2. The ceiling: ~1 ms of pause, and no throughput

A lag of 4 KiB is the best any "scan it from its own SP" rule could do, without
touching the root scan. Paired, arms alternating order across trials (ABBA),
8 trials x 10 s:

| metric | reading |
| --- | --- |
| throughput narrow/shipped | **0.989 [0.775, 1.202]** - no effect |
| pause p50 removed | **+0.970 ms [0.302, 1.638]**, 7/8 trials positive |
| nominal lag window | 27.00 MiB per collection |
| scanned after the pagemap skip | 1.53 MiB shipped, 0.38 MiB narrow |

The order matters more than the effect did: with a **fixed** arm order the same
measurement read +24% throughput for whichever arm ran second, every time. That
number is in the first run of this harness and it is an artefact - the second
arm of each pair inherits a warm CPU. ABBA removes it, and what is left is a
pause effect with no throughput effect.

## 3. The predicate is not available - and the reason is structural

A nil result from `fiber_stack_sp_scan_low` means "no thread was **found** on
this stack". It only means "no thread **is** on it" when the stop recorded an SP
for every thread, and that is what makes the rule sound in both transit
directions: a thread swapping between two fiber stacks has its SP in one of
them, and that one is scanned from the SP.

Counted with `fiber_lag_sp_known` / `fiber_lag_sp_unknown`:

| workload | lag scans | SP table complete |
| --- | --- | --- |
| `bench/fiber_lag_cost --deep`, 256 fibers x 10 collections | 2 620 | **0** |
| Kemal EC4, `-c100`, 327 collections | 34 989 | **0** |

Never, and not by luck: `stw_signal_exempt?` exempts SYSMON, the EC Monitor is
never signalled, so no SP is ever recorded for it. Every parked-fiber scan in an
execution-context build - the only configuration where the lag applies - sees an
incomplete table.

Two ways to make it complete, both measured or priced:

- **Publish the Monitor's SP at the gate.** `MonitorGate.enter` is a known
  parked point. Measured: the Monitor is parked there for **20 of 200** stops
  (10%); the rest of the time it is sleeping or running, with no SP to publish.
  Nine tenths of the payoff stays out of reach.
- **Stop exempting SYSMON.** The exemption's recorded reason is resume races
  that left it in `sigsuspend` forever - the class the stop epoch now defends
  against, with `make stw-epoch` as its red arm. This is an STW protocol change
  in the most dangerous part of the collector.

## Verdict: declined, with the arithmetic

The best case is ~1 ms off a ~6.4 ms pause p50 and nothing on throughput, and
reaching it needs either 10% of the stops or a rewrite of who gets signalled.
Not earned. The item is closed as measured rather than left standing, and what
stays behind is the instrumentation that priced it: the four counters, the
`--deep` arm, and `bench/lag_width_ab.sh`.

Also retired by these numbers: the deep synthetic arm reads 246.6 KiB per parked
fiber, the real app 16.2 KiB. The synthetic arm overstates the payoff 15x, which
is why the app was measured before anything was changed.
