# Hardening notes (Phase 5)

## Stress coverage

| Suite | Mode | What it exercises |
|-------|------|-------------------|
| `spec/stress_spec.cr` | Library `Gcry::Heap` under Boehm | Alloc storms, pointer graphs, finalizer alloc, weak links, many `push_stack` ranges |
| `samples/stress.cr` | Process GC (`-Dgc_none`) | String churn, fibers, periodic `GC.collect` |

```sh
crystal spec
crystal build -Dgc_none samples/stress.cr -o bin/stress && ./bin/stress 300
```

## Process GC tuning

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes allocated since last major GC before auto-collect (process default `67108864` / 64 MiB) |
| `GCRY_DISABLE_AUTO=1` | Disables auto-collect (`threshold = UInt64::MAX`) |
| `GCRY_NURSERY` | Opt-in nursery; sets young-bytes threshold (process GC leaves nursery **off** unless set) |
| `GCRY_DISABLE_NURSERY=1` | Forces nursery off |
| `GCRY_INCREMENTAL=1` | Experimental sliced auto-majors (unsafe without write barriers on mutating heaps) |
| `GCRY_DISABLE_INCREMENTAL=1` | Force full STW majors (process default since v0.4) |
| `GCRY_INCREMENTAL_WORK` | Objects marked per `collect_a_little` slice (default `1024`) |
| `GCRY_RELEASE_CHUNKS=1` | Munmap fully free size-class chunks after major (opt-in) |
| `GCRY_KEEP_CHUNKS=1` | Force empty chunks retained (overrides release) |

Process GC enables **majors only** by default (nursery off; full STW). Incremental auto-majors are opt-in via `GCRY_INCREMENTAL=1`. Empty-chunk release stays **opt-in** (unreleased tree pins finalizer buffers so it is crash-safe; default-on costs too much vs Boehm). Library `Gcry::Heap` leaves nursery off-threshold, `incremental_auto = false`, and `release_empty_chunks = false` unless you set them.

Inspect pauses with `Gcry.pause_stats` (`last_ns` / `p50_ns` / `p99_ns` / `max_ns` / `count`). Kemal bench exposes `GET /gc-stats` under `-Dgc_none`. `GC.stats.unmapped_bytes` tracks cumulative `munmap` from large objects and empty chunks when release is enabled.

Example:

```sh
GCRY_THRESHOLD=1048576 crystal build -Dgc_none samples/alloc.cr -o alloc && ./alloc
GCRY_DISABLE_AUTO=1 crystal run -Dgc_none samples/hello.cr
GCRY_NURSERY=262144 ./bin/alloc 1000
GCRY_DISABLE_NURSERY=1 ./bin/stress 200
GCRY_INCREMENTAL=1 ./bin/stress 200
GCRY_RELEASE_CHUNKS=1 ./bin/stress 200
./bin/json_churn 1000
```

Process GC defaults (v0.5+): majors at 64 MiB full STW; nursery off; size-class chunks retained unless `GCRY_RELEASE_CHUNKS=1`. Auto-collect is suppressed while finalizers run (avoids nested collect).

**Tuning note (Kemal `/json` wrk):** raising `GCRY_THRESHOLD` to 128–256 MiB cuts major count but pause p50 grows roughly with heap; total pause time over a fixed wrk window often stays similar, so req/s may not improve. Prefer measuring `GET /gc-stats` (`pause_p50_ns` / `pause_p99_ns` / `major_collections`) on the real app before changing the default.

OOM / fork / signals: [docs/POLICY.md](POLICY.md). Comparison checklist: [docs/COMPARISON.md](COMPARISON.md).

## False retention

gcry is **conservative**: any aligned word that looks like a heap pointer keeps that object alive.

Typical sources of extra retention:

- Stale pointers on the C stack (locals not overwritten)
- Integer / float bit patterns that alias pointers
- `/proc/self/maps` RW scans of libraries (broader than ideal; skips the managed heap)

Mitigations: nursery (young objects die faster), tighter static-root filters, precise stack maps (compiler work).

Rough check in process mode:

```crystal
before = GC.stats.heap_size
# drop references…
GC.collect
after = GC.stats.heap_size
```

`heap_size` may not shrink for small objects (chunks retained by default); with `GCRY_RELEASE_CHUNKS=1`, watch `GC.stats.unmapped_bytes` / RSS. Prefer `Gcry.default_heap.live_objects` in library tests.

## Process GC notes (HTTP / fibers)

Crystal **1.21+** defaults to `Fiber::ExecutionContext`, which does **not** call `GC.set_stackbottom` on fiber swap (only GC read locks). gcry refreshes the running fiber’s stack bottom at collect time from `Fiber.current.@stack.bottom`.

Process GC enables **stop-the-world** (`Heap#stop_the_world`): other OS threads (including the SYSMON Monitor) are signal-suspended, then their stacks are scanned (`pthread_getattr_np` for main fibers; guard page skipped for pooled fiber stacks). Mutator stack scan spills registers via `setjmp`. Without this, Monitor/register-only roots are swept and the heap corrupts under HTTP load.

Static roots scan **file-backed** readable data segments (binary / `.so`, including RELRO `r--p`) plus **BSS zero-fill**: anonymous RW pages **contiguous with** the previous file-backed RW mapping (where class vars like `Exception::CallStack::@@skip` live). Blanket “all anon &lt; 1 MiB” is unsafe — gcry large objects are also small anonymous VMAs. Large-object `munmap` does **not** invalidate the maps cache (those VMAs are never cached); empty-chunk release (`GCRY_RELEASE_CHUNKS=1`) still does. Fiber stacks are covered by `push_stack` / mutator scan (guard page clamped or leading-probe-then-bulk), not static roots.

Parallel ExecutionContexts: STW covers all OS threads, but high parallelism is not a tuned/supported production mode — see [docs/POLICY.md](POLICY.md).

## Sanitizers

Crystal + ASan/Valgrind on a custom mmap GC is limited (false positives on intentional freelist reuse).

Practical checks:

```sh
crystal spec --error-trace
crystal build -Dgc_none --debug samples/stress.cr -o bin/stress
./bin/stress 200
```

CI runs format check, specs, `-Dgc_none` samples, env-knob smoke, and `bench/churn` on Linux x86_64 for Crystal `1.21.0` and `latest` (see `.github/workflows/ci.yml`).
