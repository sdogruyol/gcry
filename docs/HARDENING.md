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
| `GCRY_THRESHOLD` | Bytes allocated since last major GC before auto-collect (process default `33554432` / 32 MiB) |
| `GCRY_DISABLE_AUTO=1` | Disables auto-collect (`threshold = UInt64::MAX`) |
| `GCRY_NURSERY` | Opt-in nursery; sets young-bytes threshold (process GC leaves nursery **off** unless set; soft-dirty arms on WSL 6.18+, HTTP still too dirty for a win) |
| `GCRY_DISABLE_NURSERY=1` | Forces nursery off |
| `GCRY_SOFT_DIRTY_MAX` | Max dirty/total % for soft-dirty page scan (default `25`; `0` = never) |
| `GCRY_DISABLE_SOFT_DIRTY=1` | Force full old→young object scan (same as max 0); may fall through to mprotect if allowed |
| `GCRY_MPROTECT_BARRIER=1` | Force mprotect+SEGV card table (process GC) |
| `GCRY_DISABLE_MPROTECT=1` | Never install mprotect barrier |
| `GCRY_INCREMENTAL=1` | Sliced auto-majors; dirty-page re-scan when a barrier is armed |
| `GCRY_DISABLE_INCREMENTAL=1` | Force full STW majors (process default since v0.4) |
| `GCRY_STRESS=1` | Collect every N allocs (`GCRY_STRESS_EVERY`, default `16`) |
| `GCRY_INCREMENTAL_WORK` | Objects marked per `collect_a_little` slice (default `1024`) |
| `GCRY_KEEP_CHUNKS=1` | Force empty chunks retained (escape hatch) |
| `GCRY_RELEASE_CHUNKS=1` | Force empty-chunk release on (process **default** already releases) |
| `GCRY_EMPTY_CHUNK_RETAIN` | Empty bytes to keep dormant with `MADV_DONTNEED` (default `0` = munmap all) |
| `GCRY_INTERIOR=1` | Allow interior pointers on **ambient roots** (default **base-pointer-only**). Heap field marks always allow interiors (`Array#shift`). |
| `GCRY_PAGE_DONTNEED=1` | Sparse free-page DONTNEED (opt-in; STW-heavy) |
| `GCRY_LARGE_CACHE` | Free large-object bytes retained after post-collect trim (default `8388608` / 8 MiB) |
| `GCRY_CHUNK_BYTES` | Size-class chunk size in bytes (default `262144` / 256 KiB; ≥64 KiB, multiple of 4096) |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | Disable root-only `type_id` plausibility filter (process default-on) |
| `GCRY_DISABLE_LAYOUT=1` | Disable `Gcry::Layout` precise heap scan |
| `GCRY_DISABLE_SP_CLAMP=1` | Do not install STW RSP capture; other-thread stacks scan full pthread range |

Process GC enables **majors only** by default (nursery off; full STW). Incremental auto-majors are opt-in via `GCRY_INCREMENTAL=1`. **Empty-chunk release is process default** (`GCRY_KEEP_CHUNKS=1` to retain). Library `Gcry::Heap` leaves nursery off-threshold, `incremental_auto = false`, and `release_empty_chunks = false` unless you set them.

Inspect pauses with `Gcry.pause_stats` (`last_ns` / `p50_ns` / `p99_ns` / `max_ns` / `count`). Kemal bench exposes `GET /gc-stats` and `GET /gc-collect` under `-Dgc_none`. `GC.stats.unmapped_bytes` tracks cumulative `munmap` from large objects and empty chunks when release is enabled.

Example:

```sh
GCRY_THRESHOLD=1048576 crystal build -Dgc_none samples/alloc.cr -o alloc && ./alloc
GCRY_DISABLE_AUTO=1 crystal run -Dgc_none samples/hello.cr
GCRY_NURSERY=262144 ./bin/alloc 1000
GCRY_DISABLE_NURSERY=1 ./bin/stress 200
GCRY_INCREMENTAL=1 ./bin/stress 200
GCRY_KEEP_CHUNKS=1 ./bin/stress 200
./bin/json_churn 1000
```

Process GC defaults (Phase 12): majors at **32 MiB** full STW; nursery off; size-class ceiling 32 KiB; **empty chunks released** unless `GCRY_KEEP_CHUNKS=1`; base-pointer-only mark; **root-only type_id gate** on (`GCRY_DISABLE_TYPE_ID_GATE=1`); layout-precise heap scan on (`GCRY_DISABLE_LAYOUT=1`); **STW SP clamp** on other OS threads (`GCRY_DISABLE_SP_CLAMP=1`). Auto-collect is suppressed while finalizers run (avoids nested collect).

**Tuning note (Kemal `/json` wrk):** raising `GCRY_THRESHOLD` to 128–256 MiB cuts major count but pause p50 grows roughly with heap; total pause time over a fixed wrk window often stays similar, so req/s may not improve. Prefer measuring `GET /gc-stats` (`pause_p50_ns` / `pause_p99_ns` / `major_collections`) on the real app before changing the default.

OOM / fork / signals: [docs/POLICY.md](POLICY.md). Comparison checklist: [docs/COMPARISON.md](COMPARISON.md). Real-app STW/sweep notes: [docs/ACIKTURKIYE.md](ACIKTURKIYE.md).

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

`heap_size` shrinks when empty size-class chunks are released (process default; `GCRY_KEEP_CHUNKS=1` retains). Watch `GC.stats.unmapped_bytes` / RSS. Large objects (&gt;32 KiB) are **cached** on a freelist after collect (no `munmap` during STW — that was multi-second on HTTP apps); reuse is **exact mapped-size** only (no fat VMA for a smaller need). Excess cache is trimmed after STW (`large_free_bytes` / `trim_large_cache` / `GCRY_LARGE_CACHE`). Prefer `Gcry.default_heap.live_objects` in library tests.

## Process GC notes (HTTP / fibers)

Crystal **1.21+** defaults to `Fiber::ExecutionContext`, which does **not** call `GC.set_stackbottom` on fiber swap (only GC read locks). gcry refreshes the running fiber’s stack bottom at collect time from `Fiber.current.@stack.bottom`.

Process GC enables **stop-the-world** (`Heap#stop_the_world`): other OS threads (including the SYSMON Monitor) are signal-suspended, then their stacks are scanned (`pthread_getattr_np` for main fibers; guard page skipped for pooled fiber stacks). Mutator stack scan spills registers via `setjmp`. Without this, Monitor/register-only roots are swept and the heap corrupts under HTTP load.

Static roots scan the **main executable** file-backed `rw-p` (and small RELRO), plus **BSS zero-fill** contiguous with prior file RW. Shared-library `.so` data segments are skipped (Crystal class/global roots live in the main binary). Large RELRO `r--p` (≥64 KiB) is skipped to cut STW on fat binaries. Large-object `munmap` does **not** invalidate the maps cache; empty-chunk release still does. Fiber stacks are scanned **once** per collect (`scan_all_fiber_roots`, not also `push_gc_roots`).

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
