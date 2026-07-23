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

Crystal has no built-in third backend. **gcry does not patch Crystal.** Instead it follows [ysbaddaden/gc](https://github.com/ysbaddaden/gc) (immix):

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

**Caveat:** `require "gcry"` must run before significant allocation that should live on the gcry heap. In practice, put it at the top of the entry file (immix does the same). `GC.init` still runs from `Crystal.main` after constants are initialized — the reopened `GC.init` must set up gcry (fiber callbacks, arenas).

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

| Method | Role |
|--------|------|
| `current_thread_stack_bottom : {Void*, Void*}` | Returns `{gc_thread_handler, stack_bottom}`; used when creating the main fiber |
| `set_stackbottom(stack_bottom : Void*)` | **Single-thread** (`without_mt`): update current thread stack bottom on fiber resume |
| `set_stackbottom(thread_handle : Void*, stack_bottom : Void*)` | **MT (boehm)** |
| `set_stackbottom(thread : Thread, stack_bottom : Void*)` | **MT (none)** — signature differs! |
| `push_stack(stack_top, stack_bottom)` | Mark/scan a suspended fiber stack range |
| `before_collect(&block)` | Boehm: chains into `GC_set_push_other_roots` |
| `lock_read` / `unlock_read` | Held around fiber resume under `preview_mt` |
| `lock_write` / `unlock_write` | Held from collect start until fiber roots pushed |
| `stop_world` / `start_world` | External STW; `none` implements via `Thread.suspend` |
| `pthread_create` / `join` / `detach` | Boehm wrappers; `none` uses libc. gcry can use libc until MT GC needs registration |
| `sig_suspend` / `sig_resume` | Unix + boehm only |

**MVP decision:** implement the **single-threaded** signatures (`set_stackbottom(Void*)`, no-op or simple locks). Defer `preview_mt` API variants to Phase 3.

## How Crystal discovers fiber roots (boehm)

On `GC.init`, boehm registers:

1. **Start callback** (`GC_set_start_callback`): `GC.lock_write` when a collection begins.
2. **Push other roots** (`before_collect` → `GC_set_push_other_roots`):
   - `Fiber.unsafe_each` → for each fiber **not** `.running?`, call `fiber.push_gc_roots`
   - `push_gc_roots` → `GC.push_stack(@context.stack_top, @stack.bottom)`
   - Under MT: for each thread, `GC.set_stackbottom(thread.gc_thread_handler, current_fiber.@stack.bottom)`
   - Then `GC.unlock_write`

The **running** fiber’s stack is scanned as the thread’s normal stack (stack bottom updated on context switch).

### Fiber resume (single-thread)

`Crystal::Scheduler#resume` (non-`preview_mt`):

```crystal
GC.set_stackbottom(fiber.@stack.bottom)
# then Fiber.swapcontext(...)
```

So every context switch retargets the collector’s notion of stack bottom to the fiber about to run.

### Main fiber construction

```crystal
thread.gc_thread_handler, stack_bottom = GC.current_thread_stack_bottom
@stack = Stack.new(stack, stack_bottom)
```

`Thread#gc_thread_handler` stores the Boehm thread handle for later `set_stackbottom` under MT.

## Implications for gcry

1. **Must support `push_stack` + `set_stackbottom` + a `before_collect`-equivalent** so suspended fiber stacks stay live. Without this, any non-trivial Crystal program frees live objects.
2. **Conservative scan** of `[stack_top, stack_bottom)` (ordering: boehm’s `GC_push_all_eager(bottom, top)` — verify which end is low address on Linux; Crystal passes `stack_top, stack_bottom` into `push_stack` which calls `push_all_eager(stack_top, stack_bottom)`).
3. **RW locks** can be no-ops for MVP (`without_mt` / default single-thread builds).
4. **`add_root`** in boehm currently only grows an Array — it does not call `GC_add_roots`. gcry should still scan its own root list; consider also whether to fix/align with `LibGC.add_roots` semantics later.
5. **Fork safety:** boehm sets `GC_set_handle_fork(1)`. MVP: document as unsupported or call `pthread_atfork` stubs; Phase 5+.
6. **Tracing:** optional `Crystal.trace :gc, ...` around malloc/collect when `flag?(:tracing)` — nice-to-have, not MVP.

## How immix does it (precedent)

[ysbaddaden/gc](https://github.com/ysbaddaden/gc) `src/immix.cr`:

- `require` reopens `module GC` and redefines `malloc`, `collect`, `push_stack`, …
- `push_stack` → `GC_add_roots` for suspended fibers
- `before_collect` registers a callback that walks `Fiber.unsafe_each` and calls `push_gc_roots`
- Collector core is C (`immix.a`); Crystal is the `GC` facade

gcry uses the **same facade pattern**, with the collector written in Crystal (`Gcry::*`) instead of C.

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
| `lock_*` / `stop_world` / `start_world` | No-ops until `preview_mt` |

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

- Linux x86_64, single-threaded Crystal (no `preview_mt`)
- `init`, `malloc`, `malloc_atomic`, `realloc`, `free`, `collect`, `enable`/`disable`
- `set_stackbottom(Void*)`, `push_stack`, `before_collect` (or internal equivalent wired in `init`)
- `current_thread_stack_bottom`, no-op locks
- `is_heap_ptr`, `stats` (meaningful fields)
- Conservative STW mark–sweep
- Fiber root pushing compatible with `Fiber#push_gc_roots`

### Out of scope (v0.1)

- `preview_mt` / execution contexts STW
- Precise / moving / concurrent / generational GC
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
| `src/crystal/scheduler.cr` | `set_stackbottom` on resume |
| `src/crystal/main.cr` | `GC.init` order |
| `src/crystal/system/thread.cr` | `gc_thread_handler` |
| `src/weak_ref.cr` | `is_heap_ptr` + disappearing links |
