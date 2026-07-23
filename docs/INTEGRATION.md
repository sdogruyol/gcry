# Crystal GC Integration Notes

Researched against **Crystal 1.21.0** stdlib (`/usr/share/crystal/src`). These notes freeze how gcry must plug into the runtime.

## Backend selection today

`src/gc.cr` defines shared types (`GC::Stats`, `GC::ProfStats`) and the `__crystal_malloc*` C entry points, then selects a backend:

```crystal
{% if flag?(:gc_none) || flag?(:wasm32) %}
  require "gc/none"
{% else %}
  require "gc/boehm"
{% end %}
```

Crystal has no built-in third backend. **gcry does not patch Crystal.** Instead:

1. Compile with **`-Dgc_none`** → Crystal loads stub `gc/none` (libc malloc, no collection, no libgc link).
2. **`require "gcry"`** early → reopen `module GC` and replace stub methods with the real collector.
3. `__crystal_malloc*` already call `GC.malloc` / etc., so they automatically hit the overridden methods.

```crystal
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}
```

```sh
crystal build -Dgc_none app.cr
```

**Caveat:** `require "gcry"` must run before significant allocation that should live on the gcry heap. In practice, put it at the top of the entry file. `GC.init` still runs from `Crystal.main` after constants are initialized — the reopened `GC.init` must set up gcry (fiber callbacks, arenas).

**Decision (Phase 0):** pure shard + `-Dgc_none`. No Crystal fork.

## Boot sequence

1. `Crystal.main` → `GC.init` (`crystal/main.cr`)
2. `Crystal.init_runtime` → `Thread.init`, `Fiber.init`, …

Allocations before `GC.init` must not occur, or must be safe under an uninitialized collector (bdwgc tolerates early use after `GC_init` is called first in `main`).

## Public + nodoc `GC` surface gcry must implement

Parity target is the **union** of what `gc/boehm.cr` and `gc/none.cr` expose, because the rest of the stdlib calls these unconditionally.

### Allocation

| Method | Semantics |
|--------|-----------|
| `malloc(size : LibC::SizeT) : Void*` | Zeroed; may contain pointers; tracked |
| `malloc_atomic(size : LibC::SizeT) : Void*` | Not zeroed; client promises no pointers |
| `realloc(ptr : Void*, size : LibC::SizeT) : Void*` | May move; atomic constraints preserved |
| `free(pointer : Void*) : Nil` | Explicit free (zlib, GMP, etc.) |

`gc.cr` also wraps `Int` overloads that forward to the `SizeT` versions.

### Lifecycle & control

| Method | Notes |
|--------|-------|
| `init` | Process setup; register fiber root hooks |
| `collect` | Full collection |
| `enable` / `disable` | Boehm raises if `enable` when not disabled |
| `stats` → `GC::Stats` | `heap_size`, `free_bytes`, `unmapped_bytes`, `bytes_since_gc`, `total_bytes` |
| `prof_stats` → `GC::ProfStats` | Boehm-shaped; `none` returns zeros — MVP may return zeros for unused fields |

### Roots, weak refs, finalizers

| Method | Boehm behavior | gcry MVP |
|--------|----------------|----------|
| `add_root(object : Reference)` | Appends `object_id` pointer to `@@roots` array (never passed to LibGC in current code — worth verifying usefulness) | Store in immortal root list; scan on collect |
| `add_finalizer(object : Reference)` | `GC_register_finalizer_ignore_self` → `#finalize` | Queue; run after collect |
| `add_finalizer(object)` | no-op for non-Reference | no-op |
| `register_disappearing_link(pointer : Void**)` | Used by `WeakRef` | Clear link when referent dies |
| `is_heap_ptr(pointer : Void*) : Bool` | `GC_is_heap_ptr` | True iff address in managed heap |

### Fiber / thread (nodoc — required)

Crystal **1.21.0** runtime modes:

| Flag / mode | Scheduler | Notes |
|-------------|-----------|--------|
| *(default)* | `Fiber::ExecutionContext` | Parallelism 1; MT-ready APIs; fibers may change OS thread on some blocking syscalls |
| `-Dwithout_mt` | Legacy `Crystal::Scheduler` | Escape hatch; true single OS thread |
| `-Dpreview_mt` | Legacy MT scheduler | **Deprecated** |

| Method | Role |
|--------|------|
| `current_thread_stack_bottom : {Void*, Void*}` | Returns `{gc_thread_handler, stack_bottom}`; used when creating the main fiber |
| `set_stackbottom(stack_bottom : Void*)` | **`-Dwithout_mt` only** — legacy scheduler calls this on fiber resume |
| `set_stackbottom(thread : Thread, stack_bottom : Void*)` | **`gc/none` when `!without_mt`** (ExecutionContext default) |
| `set_stackbottom(thread_handle : Void*, stack_bottom : Void*)` | **`gc/boehm` when `!without_mt`** |
| `push_stack(stack_top, stack_bottom)` | Mark/scan a suspended fiber stack range |
| `before_collect(&block)` | Boehm: chains into `GC_set_push_other_roots` |
| `lock_read` / `unlock_read` | Held around fiber swap under ExecutionContext / legacy MT |
| `lock_write` / `unlock_write` | Held from collect start until fiber roots pushed |
| `stop_world` / `start_world` | External STW; `none` implements via `Thread.suspend` |
| `pthread_create` / `join` / `detach` | Boehm wrappers; `none` uses libc |
| `sig_suspend` / `sig_resume` | Unix + boehm only |

**v0.1 decision:** support the Crystal **1.21 default** (ExecutionContext, parallelism 1). Match `gc/none`’s `set_stackbottom(Thread, Void*)` under `!without_mt`, and the single-arg form under `-Dwithout_mt`. RW locks stay no-ops; process GC enables STW (`stop_world` / other-thread stack scan) because the Monitor thread always exists. Deprecated `-Dpreview_mt` is out of scope.

## How Crystal discovers fiber roots (boehm)

On `GC.init`, boehm registers:

1. **Start callback** (`GC_set_start_callback`): `GC.lock_write` when a collection begins.
2. **Push other roots** (`before_collect` → `GC_set_push_other_roots`):
   - `Fiber.unsafe_each` → for each fiber **not** `.running?`, call `fiber.push_gc_roots`
   - `push_gc_roots` → `GC.push_stack(@context.stack_top, @stack.bottom)`
   - When `!without_mt`: for each thread, `GC.set_stackbottom(thread.gc_thread_handler, current_fiber.@stack.bottom)`
   - Then `GC.unlock_write`

The **running** fiber’s stack is scanned as the thread’s normal stack.

### Fiber resume (Crystal 1.21+)

**Default — `Fiber::ExecutionContext`:** `swapcontext` takes `GC.lock_read` / `unlock_read` only. It does **not** call `GC.set_stackbottom`. gcry therefore refreshes the running fiber’s bottom inside `before_collect` from `Fiber.current.@stack.bottom`.

**Legacy `-Dwithout_mt` — `Crystal::Scheduler#resume`:**

```crystal
GC.set_stackbottom(fiber.@stack.bottom)
# then Fiber.swapcontext(...)
```

### Main fiber construction

```crystal
thread.gc_thread_handler, stack_bottom = GC.current_thread_stack_bottom
@stack = Stack.new(stack, stack_bottom)
```

`Thread#gc_thread_handler` stores the Boehm thread handle for `set_stackbottom` when `!without_mt`.

## Implications for gcry

1. **Must support `push_stack` + stack-bottom tracking + `before_collect`** so suspended fiber stacks stay live. Under ExecutionContext, bottom must be taken from `Fiber.current` at collect time.
2. **Conservative scan** of `[stack_top, stack_bottom)` (ordering: boehm’s `GC_push_all_eager(bottom, top)` — verify which end is low address on Linux; Crystal passes `stack_top, stack_bottom` into `push_stack` which calls `push_all_eager(stack_top, stack_bottom)`).
3. **RW locks** can be no-ops for v0.1 (default ExecutionContext with parallelism 1).
4. **`add_root`** in boehm currently only grows an Array — it does not call `GC_add_roots`. gcry should still scan its own root list; consider also whether to fix/align with `LibGC.add_roots` semantics later.
5. **Fork safety:** boehm sets `GC_set_handle_fork(1)`. MVP: document as unsupported or call `pthread_atfork` stubs; Phase 5+.
6. **Tracing:** optional `Crystal.trace :gc, ...` around malloc/collect when `flag?(:tracing)` — nice-to-have, not MVP.

## Shard facade pattern

gcry integrates without patching Crystal:

- `require "gcry"` under `-Dgc_none` reopens `module GC` and redefines `malloc`, `collect`, `push_stack`, …
- `before_collect` walks `Fiber.unsafe_each` and calls `push_gc_roots` for suspended fibers
- `push_stack` conservatively scans those stack ranges into the mark queue
- Collector core lives in Crystal (`Gcry::*`); `GC` is a thin facade

## Development strategy

| Mode | Purpose |
|------|---------|
| Default GC (boehm) + unit tests | Test `Gcry::Heap` as a **separate** allocator (not process GC) |
| `-Dgc_none` + `require "gcry"` | Process GC integration (Phase 4+); also useful earlier for end-to-end smoke tests |
| Without `-Dgc_none` | Do **not** require gcry as process GC — would fight Boehm |

Phase 1–2 expose `Gcry.malloc` / `Gcry.collect` / … that the `GC` reopen forwards to. That keeps heap specs runnable under Boehm.

## Phase 3 APIs (fiber / weak / finalizer)

| Method | Role |
|--------|------|
| `before_collect(&block)` | Invoked at collect start; call `push_stack` for suspended fibers |
| `push_stack(top, bottom)` | Conservatively scan a fiber stack range into the mark queue |
| `set_stackbottom` / `current_thread_stack_bottom` | Running fiber stack bounds |
| `add_finalizer(object, callback)` | Run after object is reclaimed (post-collect) |
| `register_disappearing_link(link, object?)` | Clear `*link` when referent is collected |
| `lock_*` / `stop_world` / `start_world` | Locks no-op; process GC STW suspends other OS threads |

Phase 4 will reopen Crystal’s `GC` module and register:

```crystal
Gcry.before_collect do
  Fiber.unsafe_each do |fiber|
    fiber.push_gc_roots unless fiber.running?
  end
end
```

(`Fiber#push_gc_roots` → `GC.push_stack` → `Gcry.push_stack`.)


### In scope (v0.1)

- Linux x86_64, Crystal `>= 1.21` default `Fiber::ExecutionContext` (parallelism 1)
- `init`, `malloc`, `malloc_atomic`, `realloc`, `free`, `collect`, `enable`/`disable`
- `set_stackbottom` matching `gc/none` (`Thread` form when `!without_mt`; `Void*` under `-Dwithout_mt`)
- `push_stack`, `before_collect` (wired in `init`; refresh running fiber bottom from `Fiber.current`)
- `current_thread_stack_bottom`, no-op locks
- `is_heap_ptr`, `stats` (meaningful fields)
- Conservative STW mark–sweep
- Fiber root pushing compatible with `Fiber#push_gc_roots`

### Out of scope (v0.1)

- Parallel ExecutionContexts / multi-thread STW
- Deprecated `-Dpreview_mt`
- Precise / moving / concurrent GC (nursery without barriers is in scope)
- Windows / macOS
- Full `prof_stats` fidelity
- Fork-safe collection
- Patching Crystal stdlib (shard override is enough)

## Reference paths (Crystal 1.21.0)

| Path | Why |
|------|-----|
| `src/gc.cr` | Shared API, malloc entry points, backend `require` |
| `src/gc/boehm.cr` | Full production backend; fiber hooks; LibGC FFI |
| `src/gc/none.cr` | Minimal stub; reference for no-op methods + STW sketch |
| `src/fiber.cr` | `push_gc_roots`, main fiber stack bottom |
| `src/fiber/execution_context/` | Default scheduler (1.21+); swap takes GC locks, not `set_stackbottom` |
| `src/crystal/scheduler.cr` | Legacy `-Dwithout_mt` / deprecated `-Dpreview_mt` resume path |
| `src/crystal/main.cr` | `GC.init` order |
| `src/crystal/system/thread.cr` | `gc_thread_handler` |
| `src/weak_ref.cr` | `is_heap_ptr` + disappearing links |
