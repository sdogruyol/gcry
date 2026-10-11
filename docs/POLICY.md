# Runtime policy

Product rules for **Linux** (x86_64 + aarch64) and **macOS** (arm64 + x86_64), Crystal **≥ 1.21**, default ExecutionContext (parallelism **1**). Soft-dirty / nursery barrier wins remain Linux-first.

## OOM

| Situation | Behavior |
|-----------|----------|
| Chunk / large `mmap` fails | One emergency `collect` (if idle), retry `mmap` once |
| Retry fails | `Gcry::OutOfMemoryError` |
| Bootstrap / mark-stack `mmap` fails | `OutOfMemoryError` (no emergency collect) |
| Reporting it | The error, its message, its backtrace and Crystal's unwind record are allocated from a 4 MiB reserve mapped at boot and untouched until then (no RSS), so the report does not depend on what the heap has left. Several threads can report at once. `GCRY_OOM_RESERVE_KB` sizes it, `=0` turns it off; bitmap allocator without a nursery (the default) |
| The report itself cannot be allocated | A prebuilt `OutOfMemoryError` (message says "nested raise"; backtrace is gcry's boot stack) |
| Not even that can be raised | `gcry: out of memory while reporting out of memory; aborting` on stderr, then `abort()` — never a stack overflow |

No soft heap cap, no null-return malloc. Crystal expects raise / abort.

Large objects: freelist + outside-STW trim (`GCRY_LARGE_CACHE`; Linux process default **0** / Darwin **1 MiB**, reached after every collection; between collections explicit frees may leave up to 2 MiB more cached). Empty size-class chunks: **munmap outside STW** by default (Linux dormant retain **0**; Darwin **512 KiB**; `GCRY_KEEP_CHUNKS=1` / `GCRY_EMPTY_CHUNK_RETAIN` to retain).

## Fork

| | |
|--|--|
| Default | `pthread_atfork` registered — child resets locks, STW table, maps cache, barriers |
| `GCRY_DISABLE_ATFORK=1` | No registration; post-fork GC writes to stderr and `_exit(69)` without allocating (`raise` re-enters malloc) |
| Crystal | `Process.fork` under ExecutionContext is forbidden — use `LibC.fork` + `-Dwithout_mt`, or fork+exec |

Prefer fork+exec. A child keeps allocating and collecting after reinit: only the forking thread exists there, and the reinit takes the parent's other threads — the idle-release thread among them — off Crystal's thread list, as Boehm's `GC_remove_all_threads_but_me` does (`process_spec/regression/57_fork_child_collects_spec.cr`).

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
| Extra parallel contexts | **Supported opt-in:** EC>1 + TLAB **off** + lazy (~79% `/json`); RSS stretch `GCRY_PARALLEL_DORMANT=1` (~75% @ ~4×). `GCRY_TLAB=1` / `GCRY_PARALLEL_RELEASE=1` are **unsupported** (stderr warn; research/A/B only — hang/SEGV risk). Parallel *mark* is separate and on by default: `min(2, CPUs − 1)` workers up to 7 CPUs, `CPUs / 4 + 1` (at most 8) above, serial below 32 MiB live (`GCRY_PARALLEL_MARK=1` for serial) |
| `-Dpreview_mt` | Alone: unsupported (deprecated scheduler); the build stops with the reason. With `-Dexecution_context`: the execution-context modes above |
| `-Dwithout_mt` | API works; prefer 1.21 default |

Process GC: `stop_the_world = true`. Library `Gcry::Heap` under Boehm: STW off.

## Memory back to the OS

| Kind | After reclaim |
|------|----------------|
| Large | Freelist + trim (`GCRY_LARGE_CACHE`; Linux default retain **0**) |
| Size-class chunks | Empty → **munmap** (Linux retain **0**; Darwin dormant **512 KiB**); `GCRY_KEEP_CHUNKS=1` / `GCRY_EMPTY_CHUNK_RETAIN` / warm retain escapes |
| Sparse pages | `GCRY_PAGE_DONTNEED=1` (Linux opt-in; Darwin default-on) |
| Fat-app freelist residual | `GCRY_TIGHT_GROW=1` (opt-in; acik ~0.92×; Kemal thr soft — not default) |

## Root completeness

Process-GC defaults decline no live pointer (since 2026-10-05): interior and
misaligned ambient roots, static roots, and every multi-mutator stack scanned
whole from its low-water mark (`GCRY_STW_STACK_LAG` / `GCRY_STW_PTHREAD_LAG`
default **0**). The cost is pause, not throughput: Linux CI EC4 3.07 → 4.55 ms,
EC1 unchanged, macOS ~1.22–1.25× (2026-09-26,
[SOUND-DEFAULTS.md](SOUND-DEFAULTS.md)). A non-zero lag restores the bounded
scan and is a heuristic that can miss a live pointer; `GCRY_SOUND=1` forces
the whole profile ahead of the individual knobs.

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
| Windows x86_64 / ARM64 | **Supported** (CI) — `SuspendThread` STW; see [WINDOWS.md](WINDOWS.md) |
| Other OS, Android, 32-bit | **Refused at compile time** (`src/gcry/platform/os.cr`) — keep Boehm |
