# Runtime policy

Product rules for **Linux** (x86_64 + aarch64) and **macOS** (arm64 + x86_64), Crystal **≥ 1.21**, default ExecutionContext (parallelism **1**). Soft-dirty / nursery barrier wins remain Linux-first.

## OOM

| Situation | Behavior |
|-----------|----------|
| Chunk / large `mmap` fails | One emergency `collect` (if idle), retry `mmap` once |
| Retry fails | `Gcry::OutOfMemoryError` |
| Bootstrap / mark-stack `mmap` fails | `OutOfMemoryError` (no emergency collect) |

No soft heap cap, no null-return malloc. Crystal expects raise / abort.

Large objects: freelist + outside-STW trim (`GCRY_LARGE_CACHE`; Linux process default **0** / Darwin **1 MiB**). Empty size-class chunks: **munmap outside STW** by default (Linux dormant retain **0**; Darwin **512 KiB**; `GCRY_KEEP_CHUNKS=1` / `GCRY_EMPTY_CHUNK_RETAIN` to retain).

## Fork

| | |
|--|--|
| Default | `pthread_atfork` registered — child resets locks, STW table, maps cache, barriers |
| `GCRY_DISABLE_ATFORK=1` | No registration; post-fork GC raises |
| Crystal | `Process.fork` under ExecutionContext is forbidden — use `LibC.fork` + `-Dwithout_mt`, or fork+exec |

Prefer fork+exec. Single-threaded children can keep allocating after reinit.

## Signals

**Not async-signal-safe.** Do not call `GC.malloc` / `GC.collect` from a POSIX
signal handler (or any async-signal context). Set a flag / write a pipe;
allocate on normal fibers.

Crystal `Signal.trap` callbacks run on the event loop (deferred), not inside
the async handler — allocating there is the normal mutator path. That does
**not** make the GC async-signal-safe.

## Threading

| Mode | Support |
|------|---------|
| ExecutionContext, parallelism **1** | **Supported** — STW + fiber / Monitor stacks |
| Extra parallel contexts | **Supported opt-in:** EC>1 + TLAB **off** + lazy (~79% `/json`); RSS stretch `GCRY_PARALLEL_DORMANT=1` (~75% @ ~4×). `GCRY_TLAB=1` / `GCRY_PARALLEL_RELEASE=1` are **unsupported** (stderr warn). TLAB-on research recipe (dormant32 + `TLAB_SKIP_FIND_BLOCK`; thr ~⅗ of TLAB-off) — [PARALLEL_TLAB_ON.md](PARALLEL_TLAB_ON.md); not promoted. `GCRY_PARALLEL_MARK` often **hurts** HTTP — measure |
| `-Dpreview_mt` | Unsupported (deprecated) |
| `-Dwithout_mt` | API works; prefer 1.21 default |

Process GC: `stop_the_world = true`. Library `Gcry::Heap` under Boehm: STW off.

## Memory back to the OS

| Kind | After reclaim |
|------|----------------|
| Large | Freelist + trim (`GCRY_LARGE_CACHE`; Linux default retain **0**) |
| Size-class chunks | Empty → **munmap** (Linux retain **0**; Darwin dormant **512 KiB**); `GCRY_KEEP_CHUNKS=1` / `GCRY_EMPTY_CHUNK_RETAIN` / warm retain escapes |
| Sparse pages | `GCRY_PAGE_DONTNEED=1` (Linux opt-in; Darwin default-on) |
| Fat-app freelist residual | `GCRY_TIGHT_GROW=1` (opt-in; acik ~0.92×; Kemal thr soft — not default) |

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
| macOS arm64 / x86_64 | **Supported** (CI `macos-latest`) — Mach STW + dyld roots; Crystal **≥ 1.21**; soft-dirty N/A |
| musl | Best-effort — verify SP clamp |
