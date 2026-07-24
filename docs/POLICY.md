# Runtime policy

Product rules for **Linux** (x86_64 + aarch64), Crystal **≥ 1.21**, default ExecutionContext (parallelism **1**). macOS process GC is not ready yet.

## OOM

| Situation | Behavior |
|-----------|----------|
| Chunk / large `mmap` fails | One emergency `collect` (if idle), retry `mmap` once |
| Retry fails | `Gcry::OutOfMemoryError` |
| Bootstrap / mark-stack `mmap` fails | `OutOfMemoryError` (no emergency collect) |

No soft heap cap, no null-return malloc. Crystal expects raise / abort.

Large objects: freelist + outside-STW trim (`GCRY_LARGE_CACHE`, default **8 MiB**). Empty size-class chunks: **munmap outside STW** by default (`GCRY_KEEP_CHUNKS=1` to retain).

## Fork

| | |
|--|--|
| Default | `pthread_atfork` registered — child resets locks, STW table, maps cache, barriers |
| `GCRY_DISABLE_ATFORK=1` | No registration; post-fork GC raises |
| Crystal | `Process.fork` under ExecutionContext is forbidden — use `LibC.fork` + `-Dwithout_mt`, or fork+exec |

Prefer fork+exec. Single-threaded children can keep allocating after reinit.

## Signals

**Not async-signal-safe.** Do not call `GC.malloc` / `GC.collect` from a handler. Set a flag / write a pipe; allocate on normal fibers.

## Threading

| Mode | Support |
|------|---------|
| ExecutionContext, parallelism **1** | **Supported** — STW + fiber / Monitor stacks |
| Extra parallel contexts | **Experimental** — `GCRY_TLAB=1`; `GCRY_PARALLEL_MARK=N` often **hurts** HTTP thr — measure |
| `-Dpreview_mt` | Unsupported (deprecated) |
| `-Dwithout_mt` | API works; prefer 1.21 default |

Process GC: `stop_the_world = true`. Library `Gcry::Heap` under Boehm: STW off.

## Memory back to the OS

| Kind | After reclaim |
|------|----------------|
| Large | Freelist + trim (`GCRY_LARGE_CACHE`) |
| Size-class chunks | Empty → **munmap** (default); `GCRY_KEEP_CHUNKS=1` / `GCRY_EMPTY_CHUNK_RETAIN` escapes |
| Sparse pages | `GCRY_PAGE_DONTNEED=1` (opt-in, STW-heavy) |

## Incremental / barriers

Default majors = **full STW**. `GCRY_INCREMENTAL=1` is sounder with soft-dirty or mprotect; without a barrier, sliced majors can miss stores into black objects (JSON/Hash). Prefer default unless measuring pauses.

| Backend | Role |
|---------|------|
| Soft-dirty | Preferred remembered set |
| mprotect + SEGV | Fallback (`GCRY_MPROTECT_BARRIER=1`) |
| `GCRY_DISABLE_SOFT_DIRTY=1` | Full old→young (or mprotect if forced) |

## Stress

`GCRY_STRESS=1` — collect every N allocs (`GCRY_STRESS_EVERY`, default **16**).

## Platforms

| | Process GC |
|--|------------|
| Linux x86_64 | **Supported** |
| Linux aarch64 | **Supported** (CI) |
| macOS | **Not yet** — stubs compile; `-Dgc_none` raises at init |
| musl | Best-effort — verify SP clamp |
