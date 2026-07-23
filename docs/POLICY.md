# Runtime policy (Phase 7+)

How gcry behaves under failure and process lifecycle edges. These are intentional
product decisions for Linux x86_64 under Crystal **1.21+** defaults
(`Fiber::ExecutionContext`, parallelism 1).

## Out of memory (OOM)

| Situation | Behavior |
|-----------|----------|
| `mmap` for a new chunk / large object fails | One **emergency** `collect` (if not already collecting), then retry `mmap` once |
| Retry still fails | Raise `Gcry::OutOfMemoryError` |
| Bootstrap (`GC.init` not ready) `LibC.malloc` fails | Raise `Gcry::OutOfMemoryError` |
| Mark-stack growth `mmap` fails | Raise `Gcry::OutOfMemoryError` (no emergency collect) |

Notes:

- Auto-collect already runs before most allocations when thresholds are hit; the emergency path covers hard OS refusal after that.
- Large objects are `munmap`'d on reclaim. Fully free size-class chunks may be `munmap`'d after a major when `GCRY_RELEASE_CHUNKS=1` (opt-in; unreleased tree pins finalizer buffers so this is crash-safe).
- There is no soft heap limit or `malloc` null-return mode. Crystal codepaths expect exceptions (or abort) on OOM.

## Fork safety

**Unsupported for continued Crystal execution in the child.**

| Concern | Policy |
|---------|--------|
| Child inherits heap / freelist / mark state | Undefined if GC runs |
| `pthread_atfork` | Not auto-registered; `GC.note_fork_child` poison API exists for integrators |
| Recommended pattern | `fork` + immediate `exec`, or avoid forking after `GC.init` |

v0.4 skeleton only **detects** post-fork GC; it does **not** reinitialize the heap (unlike bdwgc’s `GC_set_handle_fork`). Prefer Boehm if you need a live forking server.

## Signal safety

**Not async-signal-safe.**

- Do not call `GC.malloc`, `GC.collect`, or other gcry entry points from a signal handler.
- Collection is stop-the-world on the mutator thread and walks stacks / maps; it is not reentrant.
- Crystal’s usual advice applies: signal handlers should only set flags / write to a pipe; allocate and collect on normal fibers.

## Threading / ExecutionContext (Crystal 1.21+)

| Mode | Support |
|------|---------|
| Default `Fiber::ExecutionContext` (parallelism 1) | **Supported** — stack bottom refreshed from `Fiber.current` at collect |
| Resizing default context / extra parallel contexts | **Unsupported** — `stop_world` / `start_world` are no-op stubs (v0.4 skeleton) |
| Legacy `-Dpreview_mt` | **Unsupported** (deprecated in Crystal) |
| Legacy `-Dwithout_mt` (`Crystal::Scheduler`) | Works for API shape; prefer the 1.21 default |

Do not run fibers in parallel on multiple OS threads with gcry as process GC.

## Returning memory to the OS

| Allocation kind | After reclaim |
|-----------------|---------------|
| Large objects | `munmap` — RSS can shrink; counted in `GC.stats.unmapped_bytes` |
| Size-class chunks | Kept mapped by default; `GCRY_RELEASE_CHUNKS=1` munmaps fully free chunks after major |

## Incremental mark (process GC)

Default is **full STW majors**. `GCRY_INCREMENTAL=1` enables sliced auto-majors but is **experimental** without write barriers: pointer stores into already-scanned objects can be missed (JSON/Hash workloads). Prefer the default unless measuring pause trade-offs on known-safe code.
