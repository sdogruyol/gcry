# Runtime policy (Phase 7+)

How gcry behaves under failure and process lifecycle edges. These are intentional
product decisions for **Linux** (x86_64 and aarch64) under Crystal **1.21+** defaults
(`Fiber::ExecutionContext`, parallelism 1). macOS process GC is not supported yet
(Mach STW / dyld roots stubbed; see below).

## Out of memory (OOM)

| Situation | Behavior |
|-----------|----------|
| `mmap` for a new chunk / large object fails | One **emergency** `collect` (if not already collecting), then retry `mmap` once |
| Retry still fails | Raise `Gcry::OutOfMemoryError` |
| Bootstrap (`GC.init` not ready) `LibC.malloc` fails | Raise `Gcry::OutOfMemoryError` |
| Mark-stack growth `mmap` fails | Raise `Gcry::OutOfMemoryError` (no emergency collect) |

Notes:

- Auto-collect already runs before most allocations when thresholds are hit; the emergency path covers hard OS refusal after that.
- Large objects are recycled onto a size-bucket freelist on reclaim (no `munmap` during STW). Excess free large mappings are trimmed outside STW (`trim_large_cache`; retain limit via `GCRY_LARGE_CACHE`, default **8 MiB**). Fully free size-class chunks are queued during major sweep and `munmap`'d **outside STW** by default (`GCRY_KEEP_CHUNKS=1` to retain; finalizer buffers are pinned so release is crash-safe).
- There is no soft heap limit or `malloc` null-return mode. Crystal codepaths expect exceptions (or abort) on OOM.

## Fork safety

| Concern | Policy |
|---------|--------|
| Child inherits heap mappings | OK — single surviving OS thread |
| `pthread_atfork` | **Registered by default** on process GC; child resets locks, STW SP table, maps cache, barriers |
| `GCRY_DISABLE_ATFORK=1` | Skip registration; post-fork GC raises (poison) |
| Recommended patterns | Prefer `fork` + `exec`, or single-threaded child that keeps allocating under gcry after reinit |

`GC.note_fork_child` still exists for integrators; with atfork enabled it runs the same reinit path.

**Crystal note:** default `Fiber::ExecutionContext` does not support `Process.fork`. Use `LibC.fork` only with `-Dwithout_mt`, or `fork`+`exec`. atfork still resets gcry locks when a C-level fork occurs.

## Signal safety

**Not async-signal-safe.**

- Do not call `GC.malloc`, `GC.collect`, or other gcry entry points from a signal handler.
- Collection is stop-the-world on the mutator thread and walks stacks / maps; it is not reentrant.
- Crystal’s usual advice applies: signal handlers should only set flags / write to a pipe; allocate and collect on normal fibers.

## Threading / ExecutionContext (Crystal 1.21+)

| Mode | Support |
|------|---------|
| Default `Fiber::ExecutionContext` (parallelism 1) | **Supported** — STW suspends the Monitor (SYSMON) thread; stack bottom refreshed from `Fiber.current`; other threads' current-fiber stacks scanned after STW |
| Resizing default context / extra parallel contexts | **Experimental** — enable `GCRY_TLAB=1` for alloc-side freelist locality; STW suspends all OS threads and scans each current fiber stack. Mark stays serial (`GCRY_PARALLEL_MARK=N` is a no-op speedup until STW-exempt workers exist). Not tuned for high parallelism |
| Legacy `-Dpreview_mt` | **Unsupported** (deprecated in Crystal) |
| Legacy `-Dwithout_mt` (`Crystal::Scheduler`) | Works for API shape; prefer the 1.21 default |

Process GC sets `Heap#stop_the_world = true` (signal-suspend like `gc/none`). Library `Gcry::Heap` under Boehm leaves it off.

## Returning memory to the OS

| Allocation kind | After reclaim |
|-----------------|---------------|
| Large objects | Freelist + outside-STW trim (`GCRY_LARGE_CACHE` retain, default **8 MiB**); counted in `large_free_bytes` / `unmapped_bytes` |
| Size-class chunks | **Empty-chunk release is process default-on** (`empty_chunk_retain` default **0** → `munmap` all fully-free chunks outside STW). `GCRY_KEEP_CHUNKS=1` forces retain (higher thr / higher RSS). `GCRY_RELEASE_CHUNKS=1` forces release on. `GCRY_EMPTY_CHUNK_RETAIN` keeps up to N bytes dormant (`MADV_DONTNEED`) for fast reuse. Partial-page `MADV_DONTNEED` stays opt-in via `GCRY_PAGE_DONTNEED=1`. |

## Incremental mark (process GC)

Default is **full STW majors**. With page-dirty barriers (soft-dirty / mprotect), `GCRY_INCREMENTAL=1` can terminate a cycle by re-scanning dirty pages. Without a working barrier backend, sliced majors remain **experimental**: pointer stores into already-scanned objects can be missed (JSON/Hash workloads). Prefer the default unless measuring pause trade-offs on known-safe code.

## Stress / torture

| Variable | Effect |
|----------|--------|
| `GCRY_STRESS=1` | Process GC: collect every N allocations (`GCRY_STRESS_EVERY`, default **16**) — CI / dogfood torture |

## Write barriers (shard-only)

| Backend | Role |
|---------|------|
| Linux soft-dirty | Preferred remembered-set for nursery old→young and incremental dirty re-scan |
| `mprotect` + SEGV | Fallback card table when soft-dirty is unavailable (`GCRY_MPROTECT_BARRIER=1` to force) |
| `GCRY_DISABLE_SOFT_DIRTY=1` | Force full old→young object scan (or mprotect if enabled) |

## Platforms

| Platform | Process GC (`-Dgc_none`) | Notes |
|----------|--------------------------|-------|
| Linux x86_64 | **Supported** | Primary; STW SP clamp, soft-dirty, atfork |
| Linux aarch64 | **Supported** | STW SP via `uc_mcontext.sp` (glibc offset); CI native runner |
| macOS (Darwin) | **Not yet** | Platform stubs compile; `-Dgc_none` raises at `GC.init` until Mach STW + dyld roots |
| musl / Alpine | Best-effort | Prefer gnu; verify SP offset if enabling SP clamp |
