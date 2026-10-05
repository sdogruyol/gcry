# RFC: a Crystal-implemented GC backend in crystal-lang/crystal

Status: draft for discussion upstream. Answers `docs/DEFAULT-GC-READINESS.md`
B6. Every claim below names the file, line or bench log it rests on; paths
under `src/gc*`, `src/compiler/` and `src/crystal/` are Crystal 1.21.0's, the
rest are this repository's.

## Summary

Crystal chooses its collector at compile time and knows two: Boehm and
`gc/none`. gcry is a conservative mark–sweep collector written in Crystal. It
works today without a compiler patch by filling in `gc/none` (`-Dgc_none` +
`require "gcry"`, [INTEGRATION.md](INTEGRATION.md)), at the cost of reading
private runtime state and reopening runtime classes. This RFC proposes:

1. a third backend slot, `src/gc/gcry.cr`, selected by `-Dgc_gcry`;
2. a small, named runtime↔GC interface to replace the private reads;
3. three stdlib/compiler fixes gcry found that also affect Boehm programs;
4. the interpreter's `GC_*` ABI, which gcry now exports;
5. a staged rollout: opt-in flag → Linux default → other platforms.

## Evidence that it works

- **Crystal's whole `spec/std` passes under gcry**: 1.21.0, 18 054 examples,
  0 failures, 0 errors, 30 pending — identical to Boehm — and the same under
  `GCRY_STRESS=1 GCRY_STRESS_EVERY=256` and `GCRY_SOUND=1`; 1.21.1: 18 068, 0
  failures (`docs/DEFAULT-GC-READINESS.md` §1). CI runs it on every push
  (`ci/std-spec.sh`, job `std-spec` in `.github/workflows/ci.yml`), against the
  `spec/std` of the compiler's own commit.
- **Root-complete defaults.** Since 2026-10-05 no default knob can decline a
  live pointer: the multi-mutator stack lags are 0
  (`src/gcry/collect_scan.cr`, `stw_multi_stack_lag` /
  `stw_multi_pthread_lag`), pinned by
  `process_spec/regression/14_sound_defaults_spec.cr`. Cost: Linux EC4 pause
  3.07 → 4.55 ms with req/s unchanged, EC1 unchanged, macOS pause ~1.22–1.25×
  (2026-09-26 CI matrix, README "What the default heuristics cost").
- **Throughput and memory.** Kemal `/json` 112.6% [106.6, 118.6] of Boehm at
  1.07× peak RSS on Linux (`bench/log/linux/2026-09-06-bitmap-default-ab/`,
  measured with the lags then in force); 101.9% [100.9, 103.0] at 1.50× peak
  footprint on macOS (`bench/log/macos/2026-09-06-bitmap-default-ab/`). CI
  perf smoke, v0.34.0 window: Linux `/json` 104.8%, `/` 100.8%, peak RSS 0.96×
  (`bench/leaderboard.md`).
- **The compiler self-hosts with gcry.** A compiler built with gcry builds
  itself. `compiler_spec` passes: 13 641 examples, 0 failures, the same as
  Boehm. `crystal i` runs in the gcry-built compiler (3 of 3 programs).
  - CI runs all of this on every push (`ci/compiler-spec.sh`, job
    `compiler-gcry`).
  - The gcry-built compiler compiles 4–5% slower than the Boehm-built one.
- **Platforms.** Linux x86_64/aarch64, macOS arm64/x86_64, Windows
  x86_64/ARM64 ([WINDOWS.md](WINDOWS.md)). Any other target is refused at
  compile time rather than miscompiled (`src/gcry/platform/os.cr:10-16`).

What is **not** evidenced yet:

- Allocation-storm throughput lags Boehm: Primes 77% and JsonParsePure 79%
  of its speed on a 12-CPU Linux host (READINESS M2).
- Crystal's suites have run under gcry only on Linux x86_64.
- TLAB, under Parallel ExecutionContext, remains a research arm (B3,
  [POLICY.md](POLICY.md)).

## 1. Backend selection

Today (`src/gc.cr:139-143`):

```crystal
{% if flag?(:gc_none) || flag?(:wasm32) %}
  require "gc/none"
{% else %}
  require "gc/boehm"
{% end %}
```

Proposed:

```crystal
{% if flag?(:gc_gcry) %}
  require "gc/gcry"
{% elsif flag?(:gc_none) || flag?(:wasm32) %}
  require "gc/none"
{% else %}
  require "gc/boehm"
{% end %}
```

`src/gc/gcry.cr` implements the same surface as `gc/boehm.cr` ∪ `gc/none.cr`
([INTEGRATION.md](INTEGRATION.md) "What gcry must implement"), with no
`LibGC` link. Whether the collector's source lives in-tree or as a vendored
shard is for the core team; the RFC needs only the flag and the file.

One existing gate must move with it: gcry's `GC.pthread_create` wrapper only
stages the new `Thread` under `{% if flag?(:gc_none) %}`
(`src/gcry/gc_override.cr:1696-1767`). Under `-Dgc_gcry` that would compile
out silently. The backend must key those blocks on its own flag.

## 2. Runtime↔GC hooks to replace private reads

Each row is something gcry reads or reopens today, where, and the hook that
would replace it. The stdlib owns the hook; the backend calls it.

| gcry reads today | Where | Why the collector needs it | Proposed hook |
|---|---|---|---|
| `Fiber#@stack` (`.bottom`, `.pointer`) | `src/gcry/gc_override.cr:198`, `src/gcry/collect_stw.cr:973`, `src/gcry/collect_scan.cr:724`, `src/gcry/stack_scrub.cr:352`, `src/gcry/platform/windows_stack.cr:26` | Stack bounds of every fiber to scan; the running fiber's bottom is refreshed at collect because EC fiber swaps no longer call `set_stackbottom` ([INTEGRATION.md](INTEGRATION.md) "Fiber roots") | `Fiber#gc_stack_bounds : {Void*, Void*}` |
| `Fiber#@context.stack_top` | `src/gcry/collect_scan.cr:860,1214,1218,1454` | Saved SP of a parked fiber; with lag 0 the scan starts from the low-water mark, with a lag from here | `Fiber#gc_saved_stack_pointer : Void*?` (nil while running) |
| `Thread#@current_fiber`, `Thread#@main_fiber` | `src/gcry/collect.cr:1784`, `src/gcry/idle_release.cr:87`, `src/gcry/platform/windows_stack.cr:25` | Is the thread past `Thread.new` far enough to collect on it; which stack is the thread's own | `Thread#gc_current_fiber?`, `Thread#gc_main_fiber?` |
| `Thread#@name == "SYSMON"` | `src/gcry/collect.cr:1773-1774`, `src/gcry/collect_stw.cr:759-760` | The EC monitor thread is not signal-suspended; it is held off at a gate instead (`src/gcry/monitor_gate.cr:1-25`). Keyed on a name string | `Thread#gc_role : Role` (`Mutator`, `Monitor`, …) set by the runtime |
| `Thread#@system_handle` | `src/gcry/poison_holders.cr:678`; written by the Windows `beginthreadex` wrapper, `src/gcry/gc_override.cr:1673-1682` | Suspend/resume and stack query of another thread | `Thread#gc_system_handle` |
| `ExecutionContext#@schedulers`, `#@global_queue` | `src/gcry/collect_scan.cr:413-421,604-610` | Run queues and schedulers hold fibers that must be roots while the world is stopped | `Fiber::ExecutionContext.each_gc_root(&)` |
| `Fiber.@@fibers.@mutex` | `src/gcry/collect_stw.cr:980-993` (reopens `Fiber`) | Stop-the-world must not interrupt a thread inside the fiber list's mutex | `Fiber.gc_lock_list` / `Fiber.gc_unlock_list`, or a documented `GC.before_stop_world` callback |
| Reopen of `Fiber::ExecutionContext::Monitor` | `src/gcry/monitor_gate.cr:231` | The monitor wakes ~100×/s during a stop and can touch the heap; it must check a gate (`monitor_gate.cr:1-25`) | `GC.monitor_enter` / `GC.monitor_exit` called by the monitor loop (no-ops in Boehm/none) |
| `GC.pthread_create` / `GC.beginthreadex` staging | `src/gcry/gc_override.cr:1043,1696-1767`; `src/gcry/platform/thread_staging.cr:1-20` | A `Thread` is unreachable from the runtime between `pthread_create` and its own registration; Boehm closes the same gap inside `GC_pthread_create` (`src/gc/boehm.cr:170,402-403`) | Keep the existing `GC.pthread_create` / `GC.beginthreadex` entry points (they already exist for Boehm); document that a backend may root `arg` there |

Every hook is a method on a stdlib type with a trivial implementation; Boehm
and `gc/none` need not call them. The gain is that a stdlib rename becomes a
compile error in the backend instead of a silently dropped root source — the
risk READINESS B6 names, today caught only if `spec/std` happens to exercise
it.

## 3. Fixes gcry found that affect every backend

### 3.1 `raises?` is not a fixpoint (compiler)

The cleanup pass copies `raises?` from callee to caller once
(`semantic/cleanup_transformer.cr:607-609`); a callee still being transformed
through a call cycle leaves its callers with `raises? == false`, so codegen
emits `call` without a landing pad (`codegen/call.cr:511`) and a `rescue`
never runs. Stock Boehm programs hit it: `5.clamp(...3)` escapes its
`rescue` with the stock 1.21.0 compiler
(`bench/log/linux/2026-10-05-raises-cycle/stock_boehm.cr`, `min.cr`).

A Crystal-implemented GC widens the exposure, because `GC.malloc*` bodies are
Crystal and close new cycles back into the stdlib; under gcry
`String.new(Pointer(UInt8).null, 3)` became uncatchable. Stranded callers in
the five-line repro: Boehm 15, gcry 29, either with the fix 0
(`FINDINGS.md`, "Counting it").

Proposed: merge `crystal-raises-fixpoint.patch` (same directory), which
propagates `raises?` along recorded edges to a fixpoint after
`cleanup_types` and adds a codegen spec; 73/73 in
`spec/compiler/codegen/exception_spec.cr` with it. The full compiler suite
has not been run with the patch. Until then gcry carries
`src/gcry/crystal_raises_compat.cr` (`@[Raises]` on the one user-reachable
method).

### 3.2 `argv` without a NULL terminator (stdlib)

`Crystal::System::Process.prepare_args` allocates `args.size` slots
(`src/crystal/system/unix/process.cr:311-313`); `execve` requires
`argv[argc] == NULL`. Boehm hides it because `GC_malloc(16)` usually returns a
larger zeroed granule; an allocator with exact size classes exposes it as
`EFAULT` (`src/gcry/crystal_process_compat.cr:1-9`, gcry issue #14).
Proposed: allocate `args.size + 1`. A one-line fix independent of this RFC.

### 3.3 `String::Builder#to_s` writes its terminator past the buffer (stdlib)

`String::Builder#increase_capacity_by` lets the content fill `@capacity`
exactly (`new_bytesize <= @capacity`), growth is `Math.pw2ceil(new_bytesize)`,
and `to_s` then stores the NUL at `@buffer[@capacity]`
(`src/string/builder.cr:105,127,140`): one byte past the allocation whenever
header plus content is a power of two (116, 244, 500, … bytes of content), or
fills an initial `String.build(capacity)` buffer. Boehm hides it because it
adds a byte to every request (`GC_malloc_atomic(128)` is a 144-byte object);
with exact size classes the store lands on the next block, and that block's
first write (a `String`'s type id, 1) replaces the terminator. The Crystal
compiler built with gcry passed such 116-byte mangled names to LLVM, which
read them up to the next NUL, declared `…\01` functions, and failed to link
(gcry: `src/gcry/crystal_string_builder_compat.cr`,
`process_spec/regression/22_string_builder_terminator_spec.cr`). Stock
Crystal crashes on it under an allocator with no slack
(`bench/log/linux/2026-10-05-string-builder-terminator/builder_overflow.cr`,
`-Dgc_none`). Proposed: count the terminator in `increase_capacity_by`
(`crystal-string-builder-terminator.patch`, same directory; `spec/std`
`string_builder_spec`, `string_spec` and `io/memory_spec` pass with it).

## 4. The interpreter's `GC_*` ABI

`crystal i` drops `-lgc` and resolves `GC_*` from the compiler executable
itself (`src/compiler/crystal/interpreter/context.cr:441-460`).

- **What gcry exports:** Boehm's `GC_*` functions and a `GC_stackbottom`
  data symbol, plus a `lib LibGC` for shards that bind it directly
  (`src/gcry/c_abi.cr`; `process_spec/regression/21_boehm_c_abi_spec.cr`).
- **Result:** a compiler built with gcry runs `crystal i` (`ci/compiler-spec.sh`,
  `ci/compiler-interp/`).
- **Proposed:** `gc/gcry.cr` keeps these exports, so the interpreter follows
  the backend the compiler was built with. No interpreter change is needed.

## 5. Staged rollout

| Stage | What | Entry criterion (evidence) |
|---|---|---|
| 1 | `-Dgc_gcry` opt-in, all three gcry platforms; Boehm stays default | §1 and §2 merged; `spec/std` green under `-Dgc_gcry` in Crystal's CI as it is in gcry's (`ci/std-spec.sh`); §3.1 merged or the compat file shipped |
| 2 | Default on Linux x86_64/aarch64; `-Dgc_boehm` as escape hatch | `compiler_spec` and a compiler self-host under gcry, which gcry's CI already runs (`compiler-gcry`), in Crystal's CI too; Parallel ExecutionContext supported by default, which the compiler itself uses (B3); one release of stage 1 with no open live-object-loss report (B2) |
| 3 | macOS, then Windows default | Same criteria per platform |

Platforms outside these stay on Boehm; gcry already refuses to build for
them (`src/gcry/platform/os.cr:10-16`), so no target silently changes
collector.

## Open questions

- In-tree source versus vendored shard for `src/gc/gcry.cr`.
- Whether `GC.monitor_enter/exit` should be generalised into an
  "unsuspended runtime thread" protocol, since the idle collector has the
  same shape (`src/gcry/collect_scan.cr:1107-1113`).
- `GCRY_*` environment knobs ([HARDENING.md](HARDENING.md)): which, if any,
  become a supported interface upstream.
