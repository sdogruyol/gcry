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
| | Any other OS, Android, 32-bit targets — a compile-time `{% raise %}` in `src/gcry/platform/os.cr` stops the build |

**Evidence.** Crystal's whole `spec/std` passes with gcry as the process GC
(1.21.0: 18 054 examples, 0 failures — the same as Boehm; also under
`GCRY_STRESS=1` and `GCRY_SOUND=1`), and CI holds it there: `ci/std-spec.sh`,
job `std-spec` in `.github/workflows/ci.yml`, run against the compiler's own
commit (`docs/DEFAULT-GC-READINESS.md` §1).

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
| Windows CI | x86_64 and native ARM64: specs, samples, and the Linux gates that hold there |

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
