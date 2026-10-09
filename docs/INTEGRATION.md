# Crystal GC integration

How gcry becomes the process GC — Crystal **1.21+**, no compiler patch.

## Plug-in

Crystal picks a backend in `src/gc.cr`:

```crystal
{% if flag?(:gc_none) || flag?(:wasm32) %}
  require "gc/none"
{% else %}
  require "gc/boehm"
{% end %}
```

There is no third built-in. gcry **fills `gc_none`**:

1. Build with **`-Dgc_none`** (no libgc link).
2. **`require "gcry"`** early — reopens `module GC`.
3. `__crystal_malloc*` already calls `GC.*` → hits gcry.

```crystal
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}
```

```sh
crystal build -Dgc_none app.cr
```

Require before meaningful allocation. `GC.init` (from `Crystal.main`) still owns process setup — the reopened `init` wires arenas, fiber hooks, STW.

## Boot

`Crystal.main` → `GC.init` → runtime / threads / fibers. Early allocs must be safe under an uninitialized collector (same rule as Boehm: init first).

## What gcry must implement

Parity target = union of `gc/boehm.cr` and `gc/none.cr` — stdlib calls these unconditionally.

| Area | Methods |
|------|---------|
| Alloc | `malloc`, `malloc_atomic`, `realloc`, `free` |
| Control | `init`, `collect`, `enable` / `disable`, `stats`, `prof_stats` |
| Roots | `add_root`, `add_finalizer`, `register_disappearing_link`, `is_heap_ptr` |
| Fibers | `current_thread_stack_bottom`, `set_stackbottom`, `push_stack`, `before_collect` |
| STW / locks | `lock_*` (no-ops OK at parallelism 1), `stop_world` / `start_world` (process GC on) |

### Fiber roots (1.21+)

**Default ExecutionContext:** fiber swap takes GC read locks only — **no** `set_stackbottom` on resume. gcry refreshes the running bottom at collect from `Fiber.current.@stack.bottom`.

**`-Dwithout_mt`:** legacy scheduler calls `GC.set_stackbottom` on resume.

On `before_collect`: walk `Fiber.unsafe_each`, `push_stack` for non-running fibers. The running fiber is the thread stack scan.

`set_stackbottom` shape: `Thread` form when `!without_mt` (match `gc/none`); single `Void*` under `-Dwithout_mt`.

## Two test modes

| Mode | Use |
|------|-----|
| Default Boehm + `Gcry::Heap` specs | Library allocator under Boehm |
| `-Dgc_none` + `require "gcry"` | Real process GC |

Never `require "gcry"` as process GC without `-Dgc_none` — you fight Boehm.

## Scope

| In | Out |
|----|-----|
| Linux x86_64 + aarch64, macOS arm64 + x86_64, Windows x86_64 + ARM64 (see below), Crystal ≥ 1.21; EC1 default; Parallel TLAB-off + lazy **supported opt-in** | Parallel as **process default**; Parallel + TLAB / munmap |
| Full `GC` facade + STW + fiber roots | Deprecated `-Dpreview_mt` |
| Fork reinit via `pthread_atfork` | Patching Crystal for `-Dgc_gcry` (proposed upstream: [RFC-GC-BACKEND.md](RFC-GC-BACKEND.md)) |
| | Precise / moving GC without compiler maps; soft-dirty (Linux-only) |
| | Any other OS, Android, 32-bit targets — a compile-time `{% raise %}` in `src/gcry/platform/os.cr` stops the build, as the process GC and as a library heap alike (the mark reads 8-byte words; the allocator keeps a `@[ThreadLocal]` cursor). The message names the remedy for each: drop `require "gcry"`, and `-Dgc_none` with it, to keep Crystal's default GC |

**Evidence.** Crystal's whole `spec/std` passes with gcry as the process GC
on Linux x86_64 (1.21.0: 18 054 examples, 0 failures — the same as Boehm;
also under `GCRY_SOUND=1`, and under `GCRY_STRESS=1` with 0 unexpected
failures and one allowlisted example, see `ci/std-spec-stress-allow.txt`),
and CI holds it there: `ci/std-spec.sh`, job `std-spec` in
`.github/workflows/ci.yml`, run against the compiler's own commit
(`docs/DEFAULT-GC-READINESS.md` §1). macOS and Windows do not run it.

The compiler built with gcry builds itself and runs `crystal i`.
`compiler_spec`, built by the host compiler with gcry linked in (`-Dgc_none`,
`require "gcry"`) and run with gcry as the process GC, passes (13 640
examples, 0 failures, 18 pending; `bench/log/linux/2026-10-06-compiler-spec/`).
gcry exports the part of Boehm's `GC_*` C ABI Crystal uses, and a `lib LibGC`
(`src/gcry/c_abi.cr`; § Boehm's C ABI and § Boehm parity below). CI, Linux
x86_64 only: `ci/compiler-spec.sh`, job `compiler-gcry` (self-host and
`crystal i` on every push and pull request, `compiler_spec` on pull requests,
schedule and dispatch).

## Boehm's C ABI

Every `-Dgc_none` program that requires gcry defines Boehm's `GC_*` entry
points, on gcry's heap: `crystal i` resolves its interpreted program's
`LibGC` calls from the compiler binary, Crystal's `spec/std` calls
`LibGC.size`, and C code linked into the program can call them. Where gcry
has no equivalent the call prints what is missing and aborts
(`GC_set_max_heap_size`). Behaviour that differs from a plain reading of
the names, each pinned by a regression:

| Call | gcry, as Boehm | Regression |
|------|----------------|------------|
| `GC_gcollect`, `GC.collect` | Nothing while collection is disabled (`GC_disable` / `GC.disable`, nested). gcry's own emergency collection already declined while disabled, as Boehm's does. | `process_spec/regression/27_*` |
| `GC_collect_a_little` | Work only if an allocation would do some now — the next slice of a sliced cycle, or the collection the allocation debt is owed — then 1 while a sliced (`GCRY_INCREMENTAL=1`) cycle is in progress, else 0; 0 while disabled. `Gcry.collect_a_little` keeps the slice-on-demand meaning. | `27_*` |
| `GC_malloc`, `GC_malloc_atomic`, `GC_realloc` | Out of memory: Boehm's warning through the warn procedure (default: stderr), then null; a failed realloc leaves the block as it was. | `28_*` |
| `GC_set_warn_proc` | Receives that out-of-memory warning — the one Boehm warning gcry has a matching condition for. gcry's own diagnostics stay on stderr. | `28_*` |
| `GC_set_start_callback` | Called on the collecting thread at the start of every collection, before the world is stopped. | `28_*` |
| `GC_set_on_collection_event` | `START`, `PRE/POST_STOP_WORLD`, `MARK_START/END`, `RECLAIM_START/END`, `PRE/POST_START_WORLD`, `END`. gcry sweeps inside the stop unless the sweep is deferred, so the reclaim pair usually precedes the start-world pair. A sliced cycle reports `START`/`MARK_START` when it begins, a stop pair per slice, the rest when it ends. | `28_*` |
| `GC_set_on_thread_event` | `THREAD_SUSPENDED` / `THREAD_UNSUSPENDED` with the `pthread_t` of each thread a stop suspends and resumes, `GC.stop_world` included. On macOS and Windows the resume is reported just before it happens. | `28_*` |
| `GC_set_on_heap_resize` | The new heap size each time the heap maps a chunk. | `28_*` |
| `GC_register_my_thread`, `GC_unregister_my_thread`, `GC_thread_is_registered`, `GC_get_stack_base`, `GC_allow_register_threads` | A thread C created goes on Crystal's thread list — what gcry stops and scans — and comes off it again; one that exits still registered is taken off by its exit key (a pthread key, an FLS slot on Windows). Linux, macOS and Windows. A stack base outside the thread's stack is refused with `GC_UNIMPLEMENTED` (3). On Linux the thread may block every signal, as C pools do: registration unblocks the suspend signal, and a resume signal it keeps blocked cannot end a later stop early (`47_*`). | `29_*`, `47_*` |
| `GC_add_roots`, `GC_remove_roots` | A range is rounded inward to whole words, ignored if that leaves none, and scanned whole, whatever its length. One entry per range: a range inside a live one, or one with the same start, is merged into it (Boehm merges same-start ranges only, and on Windows overlapping and adjacent ones too). `GC_remove_roots` drops every range wholly inside its bounds, and the next range added takes the entry over. | `41_*` |
| `GC_register_disappearing_link`, `GC_general_register_disappearing_link`, `GC_unregister_disappearing_link` | The short form's link is a field of a heap object, cleared when that object — `GC_base(link)` — dies, before its finalizer runs. A link outside the heap, null or misaligned aborts, as Boehm's "Bad arg"; no memory for the registration answers `GC_NO_MEMORY` (2). Unregistering leaves the word alone and answers 1 if there was a registration, 0 for a misaligned link. | `25_*` |

Callbacks run inside the collector, most of them with every other thread
stopped, and must not allocate: Boehm's rule. The start callback is the
exception in practice — `crystal i` installs an interpreted one, and running
it allocates — and is called before the world is stopped or the collector's
write lock taken, so that survives (`28_*`, "survives a start callback that
allocates").

**A Crystal `lib` that declares a `GC_*` name itself drops gcry's definition
of that name.** Crystal 1.21 does not emit a top-level `fun` once a later
`lib` declares the same symbol, so a shard with its own `lib LibGC` (or any
other lib) binding, say, `GC_size` fails to link with "undefined reference
to `GC_size'" — observed for `GC_malloc` and `GC_size`, identical
signatures included. Crystal code calls the C ABI through gcry's own
`LibGC`, which declares every name it defines, including the thread
registration calls stdlib does not bind; C code is unaffected.

### Linking libgc too: `-Dgcry_no_boehm_abi`

A program that links libgc itself — a C library that uses Boehm, a shard
with `@[Link("gc")]` — gets a second definition of every `GC_*` name. With a
static libgc, which Crystal's distribution ships (`lib/crystal/libgc.a`, the
first `-lgc` match through `CRYSTAL_LIBRARY_PATH`), the link fails:
`multiple definition of 'GC_malloc'`, one line per name. Build it with
**`-Dgcry_no_boehm_abi`**: gcry then defines no `GC_*` symbol and no `LibGC`,
every `GC_*` call is libgc's, and gcry remains the program's collector
through `GC.*`. `LibGC` is then the program's own binding, and a compiler
built with the flag cannot run `crystal i`, which needs gcry's `GC_*`.

With a **shared** libgc the default build links, and that is worse rather
than better: the program's own `GC_*` calls resolve to gcry's definitions
while libgc's internal calls stay inside libgc (observed with Debian's
`libgc.so`: a call to `GC_gcollect` reached the executable's definition,
`GC_strdup`'s internal `GC_malloc_atomic` stayed in libgc). Use the flag
whenever the program links libgc, statically or not.

Making gcry's definitions weak so both could coexist was measured and
rejected: against a static libgc a weak definition loses wherever the
archive member that defines the strong one is pulled in for some other
reason, so which collector serves a given `GC_*` name would depend on link
order and member layout, silently. The flag is all-or-nothing.

Two collectors in one process also share signals. On Linux, libgc's
`GC_init` installs its thread-suspend handlers on `SIGPWR` and `SIGXCPU`,
which are Crystal's — and so gcry's — stop-the-world pair; Boehm's handler
then answers gcry's stops on threads it never registered, and the process
faults at gcry's first multi-threaded collection (SIGSEGV at `0x18`). Move
Boehm's pair before anything initialises libgc:
`GC_set_suspend_signal(SIGRTMIN + 8)` and `GC_set_thr_restart_signal(SIGRTMIN + 9)`.
`make boehm-abi-optout` (`bench/boehm_abi_optout.cr`) holds all three: the
default build fails to link against a static libgc, the flag build links and
runs both collectors across threads, and the same binary with Boehm left on
`SIGPWR` faults.

## Boehm parity

gcry is compatible with the Boehm surface Crystal uses — stdlib's
`gc/boehm.cr` calls and `crystal i` — not a one-to-one copy of Boehm.
Verified against `src/gcry/c_abi.cr`, `src/gcry/gc_override.cr` and the
regressions named.

| Behaviour | Boehm | gcry | Status |
|-----------|-------|------|--------|
| `disable` nesting; collect while disabled | Counted; collect does nothing | Same | Matches (`27_*`, `18_*`) |
| `realloc(p, 0)`, `realloc(NULL, n)` | Free; malloc | Same | Matches (`31_*`) |
| `GC_register_finalizer*`: `ofn`/`ocd`, NULL removes | Old pair returned, NULL unregisters | Same | Matches (`25_*`) |
| Normal and ignore-self ordering; cycles | Topological; cycles not finalized | Same | Matches (`17_*`) |
| Disappearing link registered twice | `GC_DUPLICATE`, link follows the new object | Same | Matches (`c_abi.cr`) |
| Interior pointers; `Crystal.trace :gc` | Recognized; traced | Same | Matches (`21_*`; `gc_override.cr`) |
| Queued finalizables | Stay roots until run | Same | Matches (`26_*`) |
| Finalizer that calls `GC.collect` | Nested finalizers bounded per thread | No nesting on the same thread | Matches (`37_*`) |
| Oversize `GC_malloc` / `GC_realloc` | NULL | NULL | Matches (`39_*`) |
| `GC_pthread_create`, `GC_beginthreadex` | Registers the thread | Registers it (`GC_pthread_create` on Linux and macOS, `GC_beginthreadex` on Windows) | Matches (`40_*`) |
| `GC_add_roots`, `GC_remove_roots` | Locked; bounds rounded inward to words; same-start ranges merged (Windows: overlapping and adjacent too); scanned whole | Writers locked, the collector reads without the lock; bounds rounded the same; a range inside a live one is merged too; scanned whole | Differs: merge rule (`41_*`) |
| Roots marked in a collection's root phase | Kept | Kept: the cursor settle that zeroes pinned chunks' marks runs before any root is marked | Matches (`49_*`) |
| Loaded libraries' data | Re-walked every collection | Followed through `r_debug`, also mid-`dlopen`/`dlclose` (Linux) | Matches (`16_*`, `42_*`) |
| Mark under `-Dwithout_mt` | Safe (libgc's own locks) | Safe: serial, since `Crystal::SpinLock` is a no-op there | Matches (`38_*`) |
| `GC.add_finalizer` twice | Second replaces first | Same | Matches (`48_*`) |
| `GC_register_disappearing_link(link)` | Object is `GC_base(link)` | Same | Matches (`25_*`) |
| Allocation slack (`EXTRA_BYTES`) | Every block | Atomic blocks only | Differs (`24_*`) |
| `realloc` shrink / move | — | Shrink keeps the block; on a move the old block is left to the sweep | Differs (`30_*`) |
| `GC_invoke_finalizers` | Runs pending, returns count | Returns 0 (finalizers run by the collector) | Differs |
| `GC_set_start_callback` | Full collections, after `GC_EVENT_START` | Every collection (incl. minor, idle), before `GC_EVENT_START` | Differs (`28_*`) |
| `GC_get_suspend_signal`, `GC_get_thr_restart_signal` | Its signals; -1 on Darwin and Windows | Same | Matches (`21_*`) |
| `GC_get_prof_stats` | Returns bytes filled | Returns nothing | Differs |
| `unmapped_bytes` (stats, `GC_get_heap_usage_safe`) | Currently unmapped | Cumulative bytes returned to the OS | Differs |
| `GC_set_max_heap_size` | Heap limit | Abort | Differs |
| Foreign threads on Windows | `GC_register_my_thread`, `GC_beginthreadex`, `GC_CreateThread`, `GC_ExitThread`, `GC_endthreadex` | The first two | Matches for those two (`29_*`, `40_*`) |
| Not exported | `GC_malloc_uncollectable`, `GC_move_disappearing_link`, long links, `_no_order` / `_unreachable` finalizers, `GC_exclude_static_roots`, `GC_clear_roots`, `GC_get_heap_size`, `GC_get_gc_no`, `GC_do_blocking`, `GC_call_with_alloc_lock`, `GC_set_finalize_on_demand`, `GC_strdup`, `GC_gc_no`, `GC_pthread_exit`, `GC_pthread_cancel`, `GC_pthread_sigmask`, `GC_dlopen`, `GC_CreateThread`, `GC_ExitThread`, `GC_endthreadex` | — | Missing; none used by stdlib or `crystal i`. C compiled against Boehm's `gc.h` with `GC_THREADS` has `pthread_cancel`, `pthread_sigmask`, `dlopen` and (with `GC_HAVE_PTHREAD_EXIT`) `pthread_exit` renamed to the `GC_` ones, on Windows `CreateThread`, `ExitThread` and `_endthreadex`, and fails to link if it calls them |
| Collection trigger, marker count, mark-stack overflow | Boehm's policy | gcry's (`GCRY_*`, [POLICY.md](POLICY.md)) | Differs by design |

## Windows

Process GC runs on Windows x86_64 (Crystal's MSVC distribution) and ARM64
(the GNU/MinGW distribution). Build, platform layer and limits are in
[WINDOWS.md](WINDOWS.md).

| Need | Status |
|------|--------|
| Crystal `-Dgc_none` + reopen `GC` | Same as Linux and macOS |
| `VirtualAlloc` / `VirtualFree` arena mapping | In gcry |
| Win32 thread suspend / resume STW | In gcry (`SuspendThread` + `GetThreadContext`, FP/SIMD included) |
| Soft-dirty / mprotect barrier | Not available; full collections only |
| Large-object recycler, `realloc` page move | Linux-only; `GCRY_LARGE_RECYCLE` / `GCRY_REALLOC_MOVE` have no effect |
| Boehm C ABI | As on Linux and macOS, thread registration and `GC_beginthreadex` included; the signal getters answer -1, as Boehm's (§ Boehm parity) |
| Windows CI | x86_64 and native ARM64: specs, samples, and the Linux gates that hold there; not Crystal's `spec/std` or `compiler_spec` |
| Workload numbers | x86_64 on a 12-vCPU QEMU/KVM VM only; ARM64 unmeasured ([WINDOWS.md](WINDOWS.md)) |

## Crystal source map (1.21)

| Path | Why |
|------|-----|
| `src/gc.cr` | Shared API, backend `require` |
| `src/gc/boehm.cr` / `gc/none.cr` | Production vs stub |
| `src/fiber.cr` | `push_gc_roots`, main fiber stack |
| `src/fiber/execution_context/` | Default scheduler |
| `src/crystal/main.cr` | `GC.init` order |
| `src/weak_ref.cr` | Disappearing links |

Deeper design: [DESIGN.md](../DESIGN.md). Policy edges: [POLICY.md](POLICY.md).
