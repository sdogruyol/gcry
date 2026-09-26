# One extra thread at EC1: pause 2.7×, RSS +63% — and 0.28.0 already cut 62% of it

**Date:** 2026-09-26 · host: QEMU x86_64, 12 vCPU · Crystal 1.21.0 `--release`,
default execution context (EC1) · Kemal `/json`, `wrk -c100 -d15`, 4 reps per
config, interleaved and rotated (`bench/root_phase_ab.sh`, `key@binary` for
0.27.2) · `EXTRA_THREADS=N` in `bench/kemal/src/server.cr` parks N plain
threads on a pipe read.

## Why this shape

gcry decides "multi-mutator" by counting Crystal's threads (> 2 besides its
own idle collector). A default-context program is main + SYSMON = 2, and
ordinary work does not add threads: file I/O, `getaddrinfo`, `Process.run`,
ten concurrent reads and a 300 ms blocking `nanosleep` in a fiber all leave a
gcry build at 2 (probe run the same day). What crosses the boundary is a
thread of the program's own. `Fiber::ExecutionContext::Isolated`, the 1.21 way
to run blocking work, is one thread by construction, and so is a driver's or
logger's `Thread.new`. `[INFERENCE]` from Crystal's source; not measured here.
The fat app's cuts sat on the boundary, 2 or 3 threads from one rebuild to the
next (`../2026-08-09-105503-root-phase/`).

## Result

| config | threads (OS) | roots µs | pause ms | post-GC RSS |
|---|---:|---:|---:|---:|
| 0.28.0, no extra thread | 3 | 136 | **0.48** | **15.7 MB** |
| 0.27.2, no extra thread | 3 | 137 | 0.48 | 15.7 MB |
| 0.28.0, **one** extra thread | 4 | 837 | **1.28** | **25.6 MB** |
| 0.27.2, one extra thread | 4 | 2775 | 3.35 | 25.6 MB |

(OS thread counts include gcry's `gc-idle`, which the boundary does not count.)

- **Without an extra thread the two releases are identical** (0.48 / 0.48 ms)
  — the SYSMON guard-scan path cannot run there — which also makes that pair a
  null control for the harness.
- **With one, 0.28.0 cut the pause 3.35 → 1.28 ms (−62%)**: the SYSMON fix
  applies to any EC1 program that has crossed the boundary, not only to EC4.
- **What remains of the extra thread's cost**: pause 0.48 → 1.28 ms, root work
  136 → 837 µs, and **+10 MB RSS (+63%)**, from a thread that never allocates.

## Where the two costs come from

**RSS**: `/gc-stats` after two collections, one extra thread against none:
`fully_free_chunk_bytes` 0 → 10.1 MB, `unmapped_bytes` 9.4 MB → 0, live
data unchanged. The multi-mutator sweep keeps empty chunks mapped. The EC1
sweep munmaps them while the collecting thread holds `@block_other_heap`.
`GCRY_PARALLEL_DORMANT=1` does not recover it (25.8 MB).

**Pause**: the root scan switches to the multi-mutator shape, with a
256 KiB lag window per parked fiber and the pthread lag.

## Forcing the EC1 sweep does not work

A throwaway build that forced the EC1 sweep mode (`sweep_multi_mutator?` false,
`ec1_lazy` on) regardless of thread count **hung** under the same load with one
extra thread: main and `gc-idle` both spinning (`R`), SYSMON asleep, the
parked thread in `anon_pipe_read`. So the thread-count gate is load-bearing
beyond throughput, and relaxing it is a design change. The plausible shape is
counting only threads that allocate. It has to account for a thread suspended
inside `allocate` past `wait_if_world_stopped_other_thread`, and for the idle
collector running the collection itself. Not attempted; recorded as open in
ROADMAP.
