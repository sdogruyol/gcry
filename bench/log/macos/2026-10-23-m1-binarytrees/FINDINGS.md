# macOS Binarytrees on the M1: what the last 7 points are (2026-10-23)

ROADMAP item "macOS: Binarytrees runs at 88% of Boehm on M1 since 0.37.0",
on `release-0.39.0` (source of `6fc6665c`). The question was whether
`Heap#malloc`'s own body still has a Darwin-specific cost. It has none we
could find. No source change is shipped: the two that were tried read no faster
on the M1 and slower on Linux, and they were backed out (`3a5c964a`).

## Tools (this directory)

- `probe.sh` / `probe.yml`: the probe workflow, push-triggered on
  `probe/m1-binarytrees` (deleted afterwards), checking out the full SHA
  named in `ref:`. It builds crystal-metric per arm (`PROBE_REFS` takes an
  arm's `src/` from another commit), disassembles the allocation entry points,
  and runs `ab.py`. It can add environment-pad arms, arms with the profiler
  preloaded but idle, env-var arms, `mrs.c`, and per-phase sums from `GCRY_TRACE`.
- `pcprof.c` / `pcprof.py`: a per-instruction PC sampler for the main thread,
  preloaded with `DYLD_INSERT_LIBRARIES` or `LD_PRELOAD`. On macOS it uses
  `thread_suspend` + `thread_get_state` from a sampler thread; on Linux, a
  SIGPROF POSIX timer. Samples are annotated on `objdump` output. Samples in
  other images are named with `dladdr`.
- `envpad.py`: speed against Boehm for each environment pad.
- `mrs.c`: what `mrs tpidrro_el0` costs behind K stores, against a load
  through a global.

Two pitfalls of the tooling itself, recorded so nobody repeats them:

1. Runs 1–2 kept the sample buffer as a 32 MiB `.bss` array. gcry scans every
   image's writable data as roots, so `scan_static_ranges` showed up as 13%
   (arm64) and 21% (M1) of samples: the profiler was measuring itself. The
   buffer is now an anonymous mapping, and the static scan is ~1%.
2. Sample totals under pcprof do not track A/B wall time. Under sampling, gcry
   came out at or above Boehm on the M1 (run 3: 54 065 samples against 55 385).
   Preloading the library idle, or padding the environment, does not move the
   A/B ratio (run 5). So the perturbation comes from the sampling itself. The
   per-instruction *distribution* is usable; the totals are not.

## Runs

| run | id | what |
|---|---|---|
| 1 | [39919145181](https://github.com/sdogruyol/gcry/actions/runs/39919145181) | M1 + arm64, first profile (macOS slide wrong, `.bss` buffer) |
| 2 | [39920651593](https://github.com/sdogruyol/gcry/actions/runs/39920651593) | M1, profile (`.bss` buffer still in the roots) |
| 3 | [39921993416](https://github.com/sdogruyol/gcry/actions/runs/39921993416) | M1 + arm64, valid profiles, 30 runs per arm |
| 4 | [39926180575](https://github.com/sdogruyol/gcry/actions/runs/39926180575) | M1, arm64, x86: `lean` and `entry` arms (below) |
| 5 | [39932391303](https://github.com/sdogruyol/gcry/actions/runs/39932391303) | M1 + arm64: 7 environment pads, idle preload, `mrs.c`, `entry` |
| 6 | [39936682548](https://github.com/sdogruyol/gcry/actions/runs/39936682548) | M1 + arm64: `dc zva` at the word claim, prefetch distance 0 / 8 KiB |
| 7 | [39937695085](https://github.com/sdogruyol/gcry/actions/runs/39937695085) | 3 runners × 2 shards, 20 reps: prefetch distance 0/512/1K/2K/4K |

Run 39937642753 was cancelled: its `tip` arm was built from the wrong
source. The probe sources are commits `23d6c2c0`, `bf34abb1` (lean), `a99a0408`
(entry) and `1860624e` (`dc zva`, on `probe/m1-binarytrees-zva`, deleted).

## Where the gap is (run 5, 90 runs per collector across 9 conditions)

| `macos-latest` (M1, 3 vCPU) | Boehm | gcry | gcry − Boehm |
|---|---:|---:|---:|
| wall | 0.762 s | 0.826 s | +0.064 s (Boehm/gcry 92–94%) |
| user CPU | 0.768 | 0.792 | +0.024 (37% of the gap) |
| kernel CPU | 0.020 | 0.034 | +0.014 (22%) |
| user + kernel − wall | 0.027 | 0.000 | 0.027 (42%) |
| page faults | 2 721 | 3 607 | +33% |

On `ubuntu-24.04-arm` in the same run, gcry runs at 100–102% of Boehm, with
**3% less** user CPU than Boehm (1.093 s against 1.126 s). Kernel time is
+0.005 s there, and Boehm overlaps 0.021 s.

So the M1's ~7 points split into three parts:

- **~3 points: Boehm's work on other threads.** Boehm's user + kernel time
  exceeds its wall time by 27 ms: its parallel markers run on the runner's
  other two vCPUs. gcry marks serially below 32 MiB live, and Binarytrees'
  live set is ~0.1 MiB. In 0.36, four gcry workers cost 14 points.
- **~2 points: kernel time.** gcry takes 33% more page faults on the 16 KiB
  pages (0.014 s more kernel time). Not attributed further here
  [INFERENCE: chunk release and refault across collections, the
  `MADV_FREE_REUSABLE` path].
- **~3 points: mutator user time.** On the M1, gcry's allocation needs 3%
  more user CPU than Boehm's. On Neoverse N2 it needs 3% less, with the same
  code shape (arm64 LLVM 15 on macOS, LLVM 20 on Linux).

The profile distributions are alike on the two arm64 runners (run 3, `tip`):
`Heap#malloc` 55% (M1) and 59% (N2); `__crystal_malloc64` 9% and 10%;
`TreeNode.new` 12.5% and 8%; `TreeNode#check` 10.5% and 10.6%. Boehm's are
alike too: `GC_malloc_kind` 21% and 28%, plus `pthread_getspecific` 10.5% on
the M1, plus `_platform_memset` 9.5%.

## What was tried on the hit path, and why none of it ships

- **The `mrs tpidrro_el0` hot spot is not a Darwin cost.** On the M1, 23–29%
  of `Heap#malloc`'s samples land on the `mrs` of `Platform.tsd_read`.
  `mrs.c` (run 5) prices that read at the same as a load through a global:
  0.37 against 0.36 ns per iteration, and equal behind 4, 14 and 24 stores.
  The samples pile up there because it is the next instruction to commit
  after the entry's loads and stores, not because the read is slow.
  `pthread_getspecific` costs 1.4 ns on the M1, and Boehm pays it on every
  allocation.
- **A frameless hit path (`lean`, `bf34abb1`).** `fast_alloc` was given a
  *lean* mode in which every case that needs a call (debug hooks, an
  unpublished key slot, medium sizes, a non-unrolled clear, the threshold, a
  used-up word, the allocate-black lookup) leaves through a tail call to the
  old body. That cut the hit path from a 12-register frame to a single
  `stp x29, x30`. On the M1, `Heap#malloc` went from 558 instructions to 169,
  and its hit is ~60 instructions. Wall time against `tip` (run 4, 15 reps):
  **M1 +1.2% [−1.8, +7.7]**, arm64 **+7.4% [+5.9, +8.6]**, x86 **+5.8%
  [+4.2, +9.0]**. On Linux the thread-local accessor call still needs a
  frame, so most of the saving is lost there. The slowdown did not reproduce
  under the profiler [INFERENCE: layout].
- **A frameless `GC.malloc` entry (`entry`, `a99a0408`, on top of `lean`).**
  One load each of the fork flag, the ready flag and the default heap, then a
  tail call; the cold cases moved into `malloc_cold`. `__crystal_malloc64` was
  inlined into `TreeNode.new`. Results: run 4, M1 −0.8% [−8.6, +9.2], arm64
  +1.4%, x86 +3.6%. Run 5, against Boehm across 9 conditions: **M1 91.0–93.4%
  against `tip`'s 90.5–95.5%**, arm64 98.0–101.6% against 99.0–102.4%.

  Removing ~25 instructions and 12 stack stores per allocation moved nothing
  on the M1. Its 8-wide core is bound by latency and memory traffic there,
  not by instruction count. Both changes were backed out (`3a5c964a`).
  `make alloc-entry-frame` (regressions 79 and 86) passed on the `entry` tree:
  `stale86: control 2, fixed 0`.
- **`dc zva` of a fully free word at its claim** (run 6, probe only). This
  takes fresh lines without a read-for-ownership. M1 +3.4% [−5.7, +12.9],
  arm64 +0.0% [−2.0, +1.7]. The RFO is not the gap.
- **Environment layout** (run 5). Seven environment pads, which shift the
  initial stack, move `tip` between 90.5% and 95.5% of Boehm on the M1. That
  is within the spread; there is no aliasing cliff.
- **Prefetch-for-write distance (`GCRY_ALLOC_PFW`, default 2048).** Run 7, 20
  reps, two shards per runner:

  | runner | 0 | 512 | 1K | 4K |
  |---|---:|---:|---:|---:|
  | arm64 | **−3.2% [−4.1, −1.7]**, **−3.6% [−4.4, −2.6]** | −1.6%, −3.0% | −1.1%, −1.4% | +0.9%, +2.3% |
  | x86 | +0.3%, −2.4% | +0.9%, −1.8% | +0.4%, −1.4% | +0.4%, −0.6% |
  | M1 | +0.5% [−8.6, +8.9], −6.3% [−13.3, +12.4] | | | |

  Run 6 on the M1: −5.5% [−7.9, +13.0]. On Neoverse N2, turning the prefetch
  off is worth 3 points on Binarytrees. On the M1 the runner's spread was
  ±10% in runs 6–7, so nothing can be read from it. The two macOS shards of
  run 7 probably shared a host. Run 5, with a single macOS job, had ±2–3%.

## Open

- Turning `@alloc_pfw` off on aarch64 is a default-path candidate: −3% on
  arm64 Binarytrees in 4 of 4 shards. It needs every crystal-metric row on all
  five runners (keep rule), and on the M1 a single-job run with ≥30 reps.
- The M1's kernel share: 33% more faults than Boehm on 16 KiB pages.
- Parallel marking at Binarytrees' live set: Boehm moves ~3.5% of its run off
  the main thread on 3 vCPUs.
- `darwin_roots.cr` takes dyld image 0 as the executable (`@@exe_mh`, the
  executable's TLS block). In the constructor of a library inserted with
  `DYLD_INSERT_LIBRARIES`, image 0 was not the executable (run 1). Whether
  that still holds when `GC.init` runs is unverified. `pcprof.c` now records
  the executable's index and image 0's name at both points
  (`<out>.<pid>.images`); no run has collected that yet.
