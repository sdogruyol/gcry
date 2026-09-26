# SYSMON's stack was read whole every collection — EC4 pause 4.15 → 1.78 ms

**Date:** 2026-09-26 · host: QEMU x86_64, 12 vCPU, Linux 7.0 · Crystal 1.21.0
`--release -Dpreview_mt -Dexecution_context`, **EC parallelism 4** · Kemal
`/json`, `wrk -c100 -d15`, 4 reps per config, interleaved and rotated
(`bench/root_phase_ab.sh`, `key@binary` for master) · master = `src/` as of
`fb7226e`.

## Result

| config | n | roots µs | stacks µs | mark µs | pause ms | Δ pause vs master |
|---|---:|---:|---:|---:|---:|---:|
| tuned, master | 1090 | 3433 | 141 | 266 | 4.15 | — |
| **tuned** | 944 | **1132** | **75** | 270 | **1.78** | **−57%** |
| sound (`GCRY_SOUND=1`), master | 1076 | 3768 | 2253 | 272 | 6.60 | — |
| **sound** | 839 | **1494** | **86** | 272 | **2.15** | **−67%** |

Post-GC RSS within 1.2% across all four (85.5–86.5 MB). `mark` is unchanged,
which is what a root-scan change should look like. IQR 7–15%.

**Null control** (`null-control/`, same harness right after): master against a
byte-identical copy of itself, 4 reps — pause **4.12 against 4.14 ms (+0.4%)**,
roots +0.5%. The effect above is two orders of magnitude outside that.
**Correctness**, patched tree: `make spec` 290/0, `spec-process` 32/0,
`stw-mt-property-test-short`, `mt-property-test-short`, `scheduler-roots`,
`stw-monitor-gate` (SYSMON's own gate), `greg-roots`, `stw-lag-pause` all green,
and `make stw-mt-sample` 30 fresh seeds, 0 failed, 0 stalled.

## How it was found

The ROADMAP question was "which fibers are deeply used, and why" — `GCRY_SOUND=1`
scans parked fibers from their low-water mark, so its cost was supposed to track
touched stack. `bench/fiber_stack_depth.py` answered it from outside the
process (pagemap + `/proc/<pid>/mem`, symbolized): **none are.** Every one of
~105 fiber stacks under Kemal EC4 load is 16–24 KiB deep (p50 = p99), and the
deepest frames on them are Crystal's exception unwinder (`__crystal_raise` →
`__crystal_personality`) under `HTTP::Server#handle_client`.

So sound's residual (6.60 against 4.15 ms) was somewhere else. Splitting the
`stacks` phase with a throwaway timing build put it all in one call:
`scan_pthread_stack` — 222 ms per 100 collections under sound, 11 ms under
tuned; register spills, the SP-containing fiber and the collecting thread's own
stack were equal. Per thread, one stack stood out from the first collection on:

    PT c=0 thread=SYSMON  span=8192KiB lw_from_top=8188KiB scanned=8188KiB
    PT c=0 thread=DEFAULT-1 span=8192KiB lw_from_top=8KiB scanned=8KiB

SYSMON's stack read as touched to the bottom, with **2048 of 2049 pages
present in pagemap and 8 KiB of RSS**: every page *read*, almost none written.
Boehm's build never has such a mapping; gcry's has it as soon as it collects.

## Mechanism

1. SYSMON is never signalled (it waits out a stop in `MonitorGate`), so its
   main fiber has no suspend SP. `fiber_stack_scan_top` takes the running-fiber
   branch, and under multi-thread STW that returned `guard`: a scan of the
   whole 8 MiB, every collection. `fiber_scan_from_guard` = collections (30 of
   30) — it is always this one fiber.
2. On Linux, a read of a never-written anonymous page maps the shared zero
   page, and **pagemap reports that PTE present**. After the first collection
   the low-water predicate (present or swapped) says SYSMON's stack was touched
   to the bottom, and it goes on saying so for the life of the thread.
3. So the skip was lost twice over on that stack: the fiber-roots pass read
   8 MiB of zeros every collection (that is most of tuned's 3.4 ms of roots),
   and `scan_pthread_stack` scanned SYSMON's pthread stack to its lag floor —
   256 KiB at the default lag, the whole 8188 KiB under sound's lag 0 (that is
   sound's 2.2 ms of `stacks`).

On Darwin the same read makes the pages resident; `make lag-scan-rss` measures
that effect for parked fibers and now also runs with this path fixed.

## Fix

The running-fiber branch starts at the low-water mark, like the lag-0 path
(`low_water_or_guard`, shared by both). For a stack that does not change during
the scan it is sound by the same argument as every other skip site: a page
never faulted is zero, so `[low-water, bottom)` holds every word
`[guard, bottom)` does. A probe failure still falls back to `guard`.

**SYSMON's stack can change during the scan**, and that is the one place the
two differ. `MonitorGate` keeps SYSMON out of its *work* during a stop — stack
transfers, `StackPool#collect` — and waits for work already in flight, but it
does not park the thread: SYSMON can still run its loop and `sleep`. Frames
that exist when the probe runs are on touched pages and are scanned. A frame
pushed *during* the stop, below every page SYSMON had ever touched, is
skipped, where the old ascending scan from the guard could have read it if it
got there after the push. That needs SYSMON to reach a new depth record inside
a stop, after warm-up, in code outside the gate — and the gated work is what
touches the heap. Stated as a difference, not assumed away; no observed or
constructed case has it.

## Gate

`bench/stw_lag_pause.cr` (all three CI invocations) now reads SYSMON's
touched depth with the collector's own probe after its ~18 collections: at
most 1 MiB with the skip, and under `GCRY_STACK_LOW_WATER=0 --disabled` — the
red arm, run every time — at least 7 MiB. Measured: 8 KiB and 8188 KiB here,
8 and 16 380 KiB on the CI runner (16 MiB stacks). With the fix reverted by
hand the default arm fails at 8188 KiB.

**macOS never takes this path**: SYSMON is suspended with the other threads
there and has an SP, so `fiber_scan_from_guard` reads 0 on the runner and the
stack read 12 KiB deep even with the skip off. The check says so and asserts
nothing there; the first push asserted the red arm on macOS and went red.

## An instrument defect found on the way

The first census reported ~100 KiB "touched" at the *bottom* of 102 of 107
stacks, on Boehm as well. It was the census: a buffered read of
`/proc/<pid>/mem` over-reads past the range asked for, and those reads use
FOLL_FORCE, which goes straight through the next stack's `PROT_NONE` guard
(it keeps `VM_MAYREAD`) and maps the zero page under it. Two pagemap-only
passes: 0 bands; after the reads: 102. The census uses exact unbuffered
`pread`s now and reads 0.

## What this does not say

- **Throughput** is not measured here; the pause is per collection.
- **EC1** is untouched: the running-fiber branch only returns early under
  multi-thread STW, and Kemal at EC1 runs two threads.
- The other side of step 2 — that pagemap cannot tell a zero-page mapping from
  a written page without the PFN, which unprivileged readers get as 0 — still
  holds for any stack something else reads whole. The skip now avoids causing
  it; it does not undo it.
