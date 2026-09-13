# The parked-fiber lag reads 65.5 MB a collection, and 95% of it is the lag

Date: 2026-09-13/14 (overnight) · host: AMD Ryzen AI 9 465, Linux 7.2.4 ·
tree: `0e37fe5` · harness `bench/fiber_lag_cost.cr`

The largest open pause item says 8.4 ms of a 9.2 ms p50 pause at Kemal `-c100`
is `roots_fibers_ns`, and proposes a fix:

> a fully parked fiber (wait queue, no owning thread) has a trustworthy SP and
> can be scanned from it as on EC1; only fibers in transit need the lag

That is a change to the root scan, where being wrong is a use-after-free days
later, so it should not be attempted on an estimate. This is the estimate made
into a measurement.

## Why every parked fiber pays

`fiber_stack_scan_top` tries `fiber_stack_sp_scan_low` first, and that function
finds an SP only when some *suspended thread's* recorded SP lies inside the
fiber's stack — i.e. when the fiber is running on a thread that was stopped. A
fully parked fiber owns no thread, so it never matches, and the scan falls
through to `stack_top - lag`.

## The number

256 fibers parked 64 frames deep on a `Fiber::ExecutionContext::Parallel`, 20
collections:

| quantity | value |
|---|---|
| parked-fiber scans that paid the lag | 5 240 |
| bytes between saved SP and scan start | 1 373 634 560 |
| per collection | **65.5 MB** across 262 parked scans |
| per parked fiber | **256.0 KiB** — the lag, in full |
| low-water skips inside those windows | 266 of 5 240 scans, 69.4 MB |

Two readings, and the second is the one that was not obvious.

**The lag is paid in full** per parked fiber — 256.0 KiB, the configured window,
not some fraction of it — and the cost is exactly linear in the number of parked
fibers:

| parked fibers | per collection | scans per collection |
|---|---|---|
| 64 | 17.5 MB | 70 |
| 128 | 33.5 MB | 134 |
| 256 | 65.5 MB | 262 |
| 512 | 129.5 MB | 518 |

**And the pagemap low-water skip fires once per fiber, not once per scan.** The
skip is what makes the lag affordable on a fat app, and this is what it does
here:

| collections | parked scans | low-water skips | probe ran, nothing to skip |
|---|---|---|---|
| 1 | 262 | 266 | 0 |
| 2 | 524 | 266 | 0 |
| 4 | 1 048 | 266 | 0 |
| 20 | 5 240 | 266 | 0 |

266 skips whichever it is — the *first* scan of each parked fiber skips its whole
window (69.5 MB over 266 skips is 261 KiB each, i.e. all of it), and no scan
after that does. So every collection past the first pays 256 KiB per parked
fiber with no skip at all, which is why the roadmap's "pooled stacks lose it over
time" understates it: a fiber loses it on its own second collection.

The mechanism is narrowed but not closed. `low_water_misses` — added for exactly
this — counts a probe that ran and found a faulted page at or below the lag
floor, and it is **0**, so the later scans do not reach the probe at all;
`stack_low_water_scan` is on and the pagemap is available, which leaves the
`bottom > lagged` precondition as the thing to instrument next. That is one
counter away and it is the named next step here.

## What this does not do

It does not make the change safe. A fully parked fiber's `stack_top` is written
at swap time and is trustworthy *if* the fiber is genuinely parked, and the
predicate for "genuinely parked, not in transit" is the whole difficulty — the
same distinction `Fiber#running?` only approximates, which is why the lag exists.
The number above says the work is worth doing; the audit gates
(`make ec-queue-audit`, `make live-graph-audit`, `make mark-audit`) are what
would have to stay green while doing it, and a per-fiber high-water mark written
at swap time is the alternative the item already names.

`make fiber-lag-cost` keeps the measurement. It is research, not a gate: it
reports and it refuses to pass if no parked fiber paid the lag, since then it
has measured nothing.
