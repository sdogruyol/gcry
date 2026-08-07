# The lag-0 root scan was 99.95% zeros — EC4 pause 147 ms → 13 ms

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, `--release`,
**EC parallelism 4** (`-Dpreview_mt -Dexecution_context`). Kemal `/json`,
`wrk -c100`, 4 reps × 20 s, 3219 collections.

This closes the ROADMAP item "Cheap root scan at scale — the one blocker to
sound defaults", for the stack axis.

## What was wrong

With `stw_multi_stack_lag = 0`, `fiber_stack_scan_top` returned `guard`: every
parked fiber was scanned from the guard page to the stack bottom. A Crystal
fiber stack is **8 MiB of reserved address space**, and almost none of it is
ever written. Measured directly with `mincore` on a Kemal-shaped fiber
population:

```
69 parked fiber stacks: 552 MiB virtual, 284 KiB resident = 0.05%
  per stack: 8192 KiB virtual, 4-8 KiB touched, lowest touched page at +8184 KiB
```

So the "full" scan spent 99.95% of its time reading pages that had never been
written, one minor fault each. The same shape appears on the pthread mapping
path in `scan_pthread_stack`, which also scans its whole ~8 MiB map when
`stw_multi_pthread_lag = 0` and SP sits on a pool fiber.

## The fix, and why it is not a precision trade

Start the scan at the stack's **low-water mark** instead of at `guard`. A page
that has never been faulted is zero and cannot hold a pointer, so
`guard → bottom` and `low_water → bottom` see *exactly the same words*. This
removes cost without narrowing what the collector can find — it is not a
conservatism knob.

`mincore(2)` is the obvious tool and is the wrong one: it answers "resident", so
a page that was written and later swapped out reads as absent, and skipping it
would drop a root. `/proc/self/pagemap` separates the two — bit 63 present,
bit 62 swapped — and a page with neither was never faulted. That is the test
used (`Platform.stack_low_water`), so memory pressure cannot turn this into a
missed root. Any failure to read pagemap falls back to the full range, so the
degradation direction is always "scan more".

Applied to both paths: parked fibers (`fiber_stack_scan_top`) and the pthread
mapping (`scan_pthread_stack`).

## Result

| Config | roots µs | stacks µs | pause µs | Δpause |
|--------|---------:|----------:|---------:|-------:|
| tuned | 6218 | 331 | 7084 | — |
| `GCRY_SOUND=1` (low-water on) | 11049 | 1555 | **12984** | **+83.3%** |
| `GCRY_SOUND=1 GCRY_STACK_LOW_WATER=0` (old) | 140777 | 5726 | **147157** | **+1977.4%** |

**EC4 pause for the sound profile: 147 ms → 13 ms, an 11.3× reduction.** Post-GC
RSS is unchanged across all three (+0.3%), so nothing was traded for it.

The synthetic guard agrees and is cheaper to re-run: `make stw-lag-pause` went
from **13.9×** to **1.03×** on the `stack_lag0` row.

## Read the spread before quoting a median

The harness flagged `sound` as multimodal (root-phase IQR 70% of median) and
refused to summarise it. That flag is correct and the reason is worth stating,
because it is the optimisation working rather than a broken run:

```
tuned       p5/p50/p95:   6083 /   6218 /   7836 µs   (IQR  4.4%)
sound       p5/p50/p95:   3401 /  11051 /  19108 µs   (IQR 70.1%)
sound-nolw  p5/p50/p95: 140029 / 140786 / 142339 µs   (IQR  0.6%)
```

The old path scanned 8 MiB per fiber every time, so its cost was a constant —
hence an IQR of 0.6%. The new path's cost tracks how much stack was *actually*
touched, which varies collection to collection. A wide distribution is the
expected signature.

The conclusion does not depend on where the statistic is taken: `sound`'s **p95**
(19.1 ms) is still 7.3× below `sound-nolw`'s **p5** (140.0 ms).

One tail is worth noting: `sound`'s p5 (3.4 ms) is *below* `tuned`'s p5
(6.1 ms). `tuned` scans `[sp − 256 KiB, bottom)`, and that window can include
untouched pages, so on some collections lag-0-with-low-water is cheaper than
lag-256 KiB. The same skip should therefore help the default path too — not
done here, and it is a separate change.

## Limits

- One host, one workload, EC4. The fat app's large-heap case (14.5× on
  `2026-08-06-100611-root-phase/`) has not been re-cut against this.
- The two EC4 runs taken today are **not** comparable to each other: `tuned`
  pause was 18.0 ms in `…-095320-root-phase/` and 7.1 ms here. Only the
  within-run comparisons above are used.
- The residual +83.3% is not attributed. It is no longer a constant worst case,
  so attributing it means asking which fibers are deeply used and why.
- Linux only. Darwin keeps the full scan; there is no pagemap equivalent wired.
