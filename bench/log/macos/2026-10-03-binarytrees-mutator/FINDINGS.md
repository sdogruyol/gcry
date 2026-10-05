# macOS: Binarytrees' gap to Boehm is in the mutator, not the collector

crystal-metric Binarytrees runs at 77–78% of Boehm's speed on macos-latest
(arm64) against 84–100% on the other platforms
(`../../linux/2026-10-03-crystal-metric-cross-platform/`). Measured on GitHub
runners, gcry at `c472941`; scripts in this directory.

## Where it is not

- **The pauses.** 131 majors (Darwin's 16 MiB threshold floor), Σ pause
  170–185 ms in a 1.19–1.29 s run, against Boehm's 0.84–0.98 s total
  (`phases.sh`). Most of it is mark; stop, stacks, sweep and flush are
  5 ms or less each.
- **The allocation fast path.** 50 M allocations in a loop (`alloc.cr`), ns
  each, three runs: `GC.malloc(48)` gcry 10.4–10.7 against Boehm 16.3–17.7;
  `AllocNode.new` (two references) gcry 10.5–11.2 against Boehm 10.8–15.7. A
  `@[ThreadLocal]` read+write costs the same under both (3.9 ns).
- **Page faults.** Binarytrees takes fewer minor faults under gcry than
  under Boehm (2 558 against 2 708), and keeping every empty chunk
  (`GCRY_KEEP_CHUNKS=1`) or 64 MiB of them warm changes neither the faults
  nor the time (`faults.sh`).
- **How often it collects.** A fixed `GCRY_THRESHOLD` of 32 or 64 MiB cuts
  the majors to 67 and 35 and the pauses to 70 and 36 ms, and the mutator
  time (run time minus Σ pause) stays at 0.94–0.98 s against Boehm's 0.77 s
  total (`thr.sh`). On Linux the same split puts gcry's mutator at
  0.74–0.75 s against Boehm's 0.71 s: there the gap *is* the pauses.
- **Chunk size, the idle collector, the single-mutator path.**
  `GCRY_CHUNK_BYTES=131072`, `GCRY_IDLE_RELEASE_MS=0` and
  `GCRY_SINGLE_MUTATOR=0` all land within the runner's noise of the default.
  `GCRY_ALLOC_FAST_PATH=0` is 3× slower, so the fast path is in use.

## What `sample` shows

`sample.sh`: macOS's `sample` on the running benchmark (not `--debug`: that
build turns inlining off and ran gcry's Binarytrees in 27 s). Main-thread
samples, gcry 374 in a 1.28 s run, Boehm 648 in 1.14 s (`sample-*.txt`):

| | gcry | Boehm |
|---|---:|---:|
| allocation (malloc, TLS, refill, block build, memset) | ~48% | ~60% |
| marking, on the main thread | ~27% | ~8% |
| `TreeNode#check` | 8% | 14% |

Boehm runs two more threads than gcry here, its parallel markers (mostly in
`__psynch_cvwait`), so its mark costs the main thread little. gcry marks on
the main thread alone. That is the shape on Linux too (`GC_MARKERS=1` Boehm
in `../../linux/2026-10-03-mark-prefilter/`), so it does not explain a gap
that is larger on macOS; the allocation share is not out of line either.

## Open

A 10–20% mutator cost on macOS arm64 that none of the above moves, with
allocation in isolation faster than Boehm's. What differs from the loop in
`alloc.cr` is that Binarytrees allocates into chunks the sweep just emptied
and then walks what it built; cursor refill and placement on a swept chunk,
or the cache behaviour of where consecutive objects land, are the next
suspects. Needs an in-process profile on macOS (`sample`/Instruments on a
runner) to go further.

## Parallel mark does not close it (2026-10-04)

`sample` put 27% of gcry's main thread in marking against Boehm's 8%, which
has parallel markers. Probe `probe-bt-macos` on `078bcb2`, 8 interleaved runs
per arm, whole-run time as % of Boehm (`GCRY_PARALLEL_MARK_MIN_LIVE=0` so the
workers run on this small heap):

| | macos-latest | ubuntu-latest |
|---|---:|---:|
| gcry | 81% | 84% |
| `GCRY_PARALLEL_MARK=2` | 80% | 88% |
| `GCRY_PARALLEL_MARK=4` | 67% | 84% |

Two workers move neither platform past its noise, four cost macOS 14 points.
The gap is not the share of marking that one thread does.

## It is user CPU, and most of it is the threshold (2026-10-05)

`/usr/bin/time -l`, 5 runs per arm, probe `probe-bt-rusage` on `5cc3ab4`
(medians; ranges in brackets):

| | macos-latest time | maxrss | involuntary csw | ubuntu-latest time | maxrss |
|---|---:|---:|---:|---:|---:|
| Boehm | 0.85 s [0.74–1.00] | 39 MB | ~1 450 | 1.18 s | 51 MB |
| gcry | 1.06 s [1.00–1.19] | 36 MB | 33–282 | 1.33 s | 22 MB |
| gcry `GCRY_IDLE_RELEASE_MS=0` | 1.02 s [0.94–1.19] | 36 MB | 29–123 | 1.34 s | 22 MB |
| gcry `GCRY_THRESHOLD=67108864` | 0.94 s [0.91–0.99] | 74 MB | 33–48 | 1.10 s | 77 MB |

On both platforms user CPU equals wall time and system time is 0.01-0.05 s
for every arm, so gcry's main thread is not blocked, faulting or descheduled
more than Boehm's. With a 64 MiB threshold gcry goes from 80% to ~90% of
Boehm on macOS (and to 106% on Linux) at about twice Boehm's peak RSS there:
most of the macOS gap is how often it collects at the RSS it keeps, which is
the open RSS-budget decision, not a mutator defect. What is left is ~5-10%.
