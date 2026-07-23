# Runtime policy (Phase 7)

How gcry behaves under failure and process lifecycle edges. These are intentional
product decisions for v0.1 on Linux x86_64 (single-threaded + fibers).

## Out of memory (OOM)

| Situation | Behavior |
|-----------|----------|
| `mmap` for a new chunk / large object fails | One **emergency** `collect` (if not already collecting), then retry `mmap` once |
| Retry still fails | Raise `Gcry::OutOfMemoryError` |
| Bootstrap (`GC.init` not ready) `LibC.malloc` fails | Raise `Gcry::OutOfMemoryError` |
| Mark-stack growth `mmap` fails | Raise `Gcry::OutOfMemoryError` (no emergency collect) |

Notes:

- Auto-collect already runs before most allocations when thresholds are hit; the emergency path covers hard OS refusal after that.
- Small size-class chunks are **retained** after reclaim (freelist reuse). Only **large** objects are `munmap`'d on collection, so emergency collect mainly helps when large garbage exists.
- There is no soft heap limit or `malloc` null-return mode. Crystal codepaths expect exceptions (or abort) on OOM.

## Fork safety

**Unsupported.** Do not rely on gcry across `fork` without `exec`.

| Concern | Policy |
|---------|--------|
| Child inherits heap / freelist / mark state | Undefined — may deadlock or corrupt on next alloc/collect |
| `pthread_atfork` handlers | Not registered (unlike bdwgc’s `GC_set_handle_fork`) |
| Recommended pattern | `fork` + immediate `exec`, or avoid forking after `GC.init` |

If you need a forking server model, prefer `Process.exec` / prefork before significant allocation, or stay on Boehm until fork support exists.

## Signal safety

**Not async-signal-safe.**

- Do not call `GC.malloc`, `GC.collect`, or other gcry entry points from a signal handler.
- Collection is stop-the-world on the mutator thread and walks stacks / maps; it is not reentrant.
- Crystal’s usual advice applies: signal handlers should only set flags / write to a pipe; allocate and collect on normal fibers.

## Threads (`preview_mt`)

Out of scope for v0.1. Locks / `stop_world` / `start_world` are no-ops. Building with `-Dpreview_mt` is unsupported.

## Returning memory to the OS

| Allocation kind | After reclaim |
|-----------------|---------------|
| Large objects | `munmap` — RSS can shrink |
| Size-class chunks | Kept mapped; blocks return to freelist / nursery freelist |

Aggressive chunk release and compaction are post–v0.1 work.
