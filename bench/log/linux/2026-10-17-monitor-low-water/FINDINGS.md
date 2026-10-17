# The Monitor's frames below its birth were not roots on Linux (2026-10-17)

Fix: `dab25144` ("scan: a running thread with no recorded sp is scanned from
its stack's low-water mark, not its fiber's stack_top"), docs `a7d229e2`,
spec 76 skipped on Windows in `31bfd814`. CHANGELOG `[Unreleased]` → Fixed,
ROADMAP "The Monitor's frames below its birth were not roots on Linux".

The probe branches named below (`probe-pf-fix-rate`) were deleted after the
work; the run ids and commits are what remains. The local gdb logs and the
scratch loops were not kept, so this file records only what the CI logs,
the tree and the spec show; the debugger findings are marked as such.

## The failure

CI run 38966033174 (branch `occupancy-claim`, since deleted, head
`4464f56e`), job `specs (x86_64, crystal 1.22.0)`: `make
bitmap-marks-freelist` died with `Invalid memory access (signal 11) at
address 0x20` in `compute_phase_stats` of `bench/pattern_fuzz.cr`. The same
job on Crystal 1.21.0 was green.

## Root cause

1. On Linux the Monitor (SYSMON) is never signal-suspended, so a
   single-mutator stop has no SP for it, and
   `scan_other_thread_fiber_ec1` fell back to its main fiber's
   `@context.stack_top`.
2. That field is written only on a context switch. The Monitor's main fiber
   never switches, so it held the SP `Fiber#initialize` read at the
   thread's birth, a few hundred bytes above the frames of the Monitor's
   loop. Those frames went unscanned.
3. Crystal 1.22's `Thread.sleep` wraps `nanosleep` in `GC.syscall do … end`;
   `req`, `rem`, `ret` and `errno` live in a 48-byte heap closure that only
   those frames reference. Crystal 1.21's `sleep` has no closure, which is
   why the 1.21 job stays green.
4. A collection during the sleep swept the closure; a mutator was handed
   the block (in `pattern_fuzz`, the six-entry `Array(PatternPhase)`
   buffer); on waking the Monitor wrote `ret`/`errno` = 0 into bytes 32-39,
   the fifth entry, and `compute_phase_stats` read that nil phase's field at
   0x20.

Debugger evidence (local, logs not kept): a hardware watchpoint on the
zeroed word caught thread "SYSMON" writing it from the `ret`/`errno`
assignments of `Thread.sleep`, and a probe in the scan showed no SP was
recorded for the Monitor in any collection.

## Fix

`src/gcry/collect_scan.cr`: when a thread has no recorded SP, the scan
starts at `low_water_or_guard(fiber, guard)` instead of
`fiber.@context.stack_top`; it is still counted in `@sp_clamp_fallbacks`
and does not read the 8 MiB from `guard` that the old clamp avoided
(`bench/log/linux/2026-09-26-sysmon-guard-scan/`).

## Rates: CI run 38981006387

Branch `probe-pf-fix-rate` (head `b2c5e2b3`, "probe: same argv0 for both
arms"), 10 jobs of `ubuntu-latest`, Crystal 1.22.0. Each job builds

```sh
crystal build -Dgc_none -Dgcry_block_headers bench/pattern_fuzz.cr -o fix/bin/pattern_fuzz_marks
git checkout 83d5c5a9 -- src          # base: release-0.37.0 before the fix
crystal build -Dgc_none -Dgcry_block_headers bench/pattern_fuzz.cr -o base/bin/pattern_fuzz_marks
```

then runs 40 iterations, base and fix alternated in each, from inside
`base/` or `fix/` so both see argv[0] `bin/pattern_fuzz_marks`, as `make
bitmap-marks-freelist` gives it:

```sh
GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 ../bench/run_bounded.sh 120 $log -- \
  bin/pattern_fuzz_marks --seed=1 --phases=40 --objects-per-phase=2000
```

The fix arm's `src/gcry/collect_scan.cr` change against `83d5c5a9` is the
same patch as `dab25144`'s (GitHub compare of both against `83d5c5a9`).

| CPU (`lscpu`)  | jobs | base fails     | fix fails |
|----------------|-----:|----------------|-----------|
| AMD EPYC 7763  | 6    | 0/40 each      | 0/40 each |
| AMD EPYC 9V74  | 2    | 30/40, 0/40    | 0/40 each |
| AMD EPYC 9V45  | 2    | 1/40, 0/40     | 0/40 each |
| all            | 10   | **31/400**     | **0/400** |

Every base failure in the logs is `Invalid memory access (signal 11) at
address 0x20` in `compute_phase_stats`.

## argv[0] moves it

CI run 38980222814 (same branch, head `2a416047`), the same A/B with the
binaries named `bin/pf_base` and `bin/pf_fix`: 0/400 in both arms, on six
EPYC 7763, two 9V45, one 9V74 and one Xeon 6973P-C. Only with argv[0] as
`make` gives it did the base fail. The program-name string is itself a heap
allocation; that it shifts which 48-byte block is handed out first is the
likely reason, not shown.

## Spec

`process_spec/regression/76_monitor_deep_frame_root_spec.cr` holds a block,
masked so no other scanned word names it, in a Monitor frame 64 KiB below
anything its birth touched (hooked into
`Fiber::ExecutionContext::Monitor#increase_parallelism`), collects three
times with lazy sweep off, and asserts the block is still allocated and
intact. It fails without the fix on both layouts on 1.22 and on 1.21, and
passes with it.

**Not run on Windows** (`31bfd814`): on all eight Windows jobs of CI run
39028591028 the Monitor never reached the hook within 10 s; why was not
investigated. The defect is Linux-only in kind: there the Monitor is never
suspended and has no SP, while on Windows and macOS a stop suspends threads
and reads their SP from the kernel. The fixed code in
`scan_other_thread_fiber_ec1` is the same on every platform.
