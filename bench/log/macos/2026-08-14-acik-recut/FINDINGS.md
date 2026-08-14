# The fat-app re-cut — 0.63× does not reproduce, and gcry is not why

**Status: ~98.0% of Boehm throughput @ ~0.97× post-GC RSS, n = 9 per arm, 0
Non-2xx in all 18 trials. This replaces the provisional 0.63×. gcry's own RSS
did not move; Boehm's dropped 35%.**

Apple M2 Pro, Darwin 25.5.0 / macOS 26.5.1 arm64. gcry at `ed8a8e5` built by
Crystal 1.21.0; acikturkiye built by probe compiler 1.22.0-dev `656fc4620`.
`acik_stackmap_ab.sh`, `VARIANTS="boehm base"`, `TRIALS=9`, `wrk -c 100 -d 30`,
`--release`, dual `/gc-collect` before the RSS read.

Current defaults confirmed **per draw** from `/gc-stats`, not assumed:
`fiber_scrub_runs = 0`, `low_water_skips = 0`, and `thread_greg_candidates = 23`
in all nine gcry draws — the register scan this release exists for is engaged in
every trial rather than inferred.

| | Boehm | gcry `base` | % Boehm | post-GC RSS × |
|--|------:|------------:|--------:|--------------:|
| req/s median | 945.3 (IQR 4.4%) | 926.7 (IQR 7.2%) | **98.0%** | |
| RSS KiB median | 37,392 (IQR 16.8%) | 36,272 (IQR 4.5%) | | **0.97×** |

## Why the harness and the variant matter

This is the *same* harness and the *same* `base` variant that produced the
0.63×. `acik_stackmap_ab.sh` issues **two** `/gc-collect` passes because
finalizer resurrect needs a second to drop dead sockets; `run_all.sh` issues
one. The 2026-08-10 `run_all.sh` number (0.98×) was never a replacement for the
0.63× because those are different post-GC states. This one is a replacement.

## What actually moved

| | 2026-08-04 (`75a9d25`, n=3) | 2026-08-14 (tip, n=9) |
|--|---:|---:|
| gcry RSS median | 36,480 KiB | **36,272 KiB** |
| Boehm RSS median | 57,568 KiB | **37,392 KiB** |
| ratio | 0.63× | **0.97×** |

**gcry's post-GC RSS is unchanged — 0.6% apart across ten days, two default
flips and a commit range.** The entire move in the ratio is Boehm's arm falling
from ~57.6 to ~37.4 MiB.

So `0.63×` was, in substantial part, a statement about that session's *Boehm*
draws rather than about this collector. It was three trials, and the Boehm side
is the noisy one here too: IQR **16.8%** against gcry's 4.5%, with two draws at
46–49 MiB pulling against seven at 36–39. The same asymmetry was recorded on the
2026-08-10 Kemal cut, where Boehm `/json` RSS carried a 10.2% IQR against gcry's
0.1%.

What did *not* change is the claim the number was introduced to make: the
v0.17-era **~18×** Darwin RSS gate is closed and stays closed. What changes is
that gcry is at parity with Boehm here, not a third below it.

## Throughput

89.9% → **98.0%**. Real at this n — 8pp against an operative floor of ±2–3pp —
but **not attributable**: between the two cuts sit a commit range
(`75a9d25` → tip), the parked-fiber scrub going opt-in, and the register fix.
Read it as where tip sits, not as anything's delta.

## Corroboration for the fix, and its limit

All 18 trials returned **0 Non-2xx**, on the arm (`base`: probe compiler +
`-Dpreview_mt -Dexecution_context`) that measured **5 of 6** corrupt before the
fix, and against a plain-`75a9d25` base rate of **7/10** re-measured on this
same compiler the same morning (`../2026-08-14-greg-control-75a9d25/`).

That is corroboration, and it is worth stating what kind: this run has no
unfixed arm of its own, so it does not on its own separate "the fix works" from
"the rate happened to be low today". The control next door is what rules the
second out.

## Two caveats on the numbers

**n = 9 is below this repo's own publishing floor.** `ROADMAP.md` sets ±2–3pp on
phase timings and ±1pp on post-GC RSS *at 12 reps*, and says to publish nothing
smaller from this host. Both moves here (34pp on the RSS ratio, 8pp on
throughput) clear that by a wide margin, but the n and the IQRs are quoted
rather than rounded away for a reason.

**One draw's `Requests/sec` is not a throughput reading.** `base` t2 reports
254.40 req/s. It is not a slow trial: per-thread `Req/Sec` was 463 (in line with
every other draw) and latency avg 107 ms / max 454 ms, but wrk finished with
`timeout 100` socket errors and ran **1.81 min instead of 30 s**, so its
`Requests/sec` divides 27,607 requests by the stalled wall time. This is exactly
the bias `bench/sound_profile_ab.sh` was rewritten to stop trusting;
`acik_stackmap_ab.sh` still takes wrk's number at face value. The median is
insensitive to it (926.69 with, 927.08 without), so nothing here is restated —
but a mean would have been wrong by 8%.

## Bistability

Not visible in these draws. Eight of nine gcry draws sit in 35.2–37.6 MiB with
one at 47.4; Boehm spans 36.3–48.8. No trough, and nothing near the ~72 MiB
regime the Linux harness stratifies on. Read that as "one regime in nine draws
on this host at this commit", not as "the bistability is gone".
