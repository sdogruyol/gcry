# Default-GC readiness review

What gcry is missing to become Crystal's **default** collector, in place of
Boehm in `crystal-lang/crystal`. Reviewed on 2026-10-04 against gcry 0.34.0
(`6650b80`). The perf rows were refreshed on 2026-10-05 from the findings
committed that day. Crystal 1.21.0 (`57cf7da50`), Linux x86_64.

**Verdict at review time (2026-10-04).** gcry was a solid opt-in shard on
Linux, macOS and Windows (x86_64/aarch64) under the default ExecutionContext
at parallelism 1. It was not ready to be the default. Every item in the
project's own "Phase 4: Crystal's Default GC" was unchecked (`ROADMAP.md`,
Phase 4), and so was the `-Dgc_gcry` compiler PR (`ROADMAP.md`, "Crystal
compiler PR").

## Status after the `readiness` branch (2026-10-05)

| ID | Status | Where |
|----|--------|-------|
| E1–E3 | **Fixed** | `layout.cr` resolve check; `Gcry.usable_size`; `crystal_raises_compat.cr` + compiler patch in `bench/log/linux/2026-10-05-raises-cycle/` |
| B1 | **Fixed**: defaults are root-complete (STW lags 0) | `collect_scan.cr`; `process_spec/regression/14` |
| B2 | **Closed**: a dying `Thread` is held until proof it is done, on every platform; the root-table race is fixed | `thread_birth_root.cr`; `make thread-death-window`; `process_spec/regression/23` |
| B3 | **Mostly closed**: parallel mark on by default; the compiler (Parallel EC at CPU count, mt codegen) builds, self-hosts and passes `compiler_spec` under gcry. TLAB and `GCRY_PARALLEL_RELEASE` stay unsupported research arms | `gc_override.cr`; `ci/compiler-spec.sh` |
| B4 | **Fixed**: compiler self-hosts with gcry, and `crystal i` runs in the gcry-built compiler (3 of 3). `compiler_spec`, built by the host compiler with gcry linked in (`-Dgc_none`, `require "gcry"`) and run with gcry as the process GC: 13 640 examples, 0 failures, 18 pending (CI run 37437660646). Linux x86_64 only | `c_abi.cr`, `crystal_string_builder_compat.cr`; CI job `compiler-gcry` (`ci/compiler-spec.sh` `step_spec`); `bench/log/linux/2026-10-06-compiler-spec/` |
| B5 | **Scoped**: unsupported targets fail at compile time with the reason | `platform/os.cr` |
| B6 | **Proposed**: upstream interface written up | `docs/RFC-GC-BACKEND.md` |
| B7 | **Fixed**: `spec/std` 18 054 / 0 failures in CI on 1.21.0, `latest` and nightly (Linux x86_64 only). The `GCRY_STRESS=1` rerun has 0 unexpected failures; one example is allowlisted (`spec/std/log/builder_spec.cr:230`, by design: it reads WeakRef-only objects after a possible collection; failed 1 of 5 255 in CI run 37592592091) | `ci/std-spec.sh`, `ci/std-spec-stress-allow.txt`, job `std-spec` |
| M1 | **Fixed**: parallel mark on by default, 32 MiB floor. Workers: `min(2, CPUs−1)` up to 7 CPUs, then `CPUs/4+1`, at most 8. Idle markers, the master included, wait on one word and are woken when work is published: a futex on Linux, `__ulock_wait` on macOS, `WaitOnAddress` on Windows (until 2026-10-08 the last two sleep-polled and their helpers took almost no work; `process_spec/regression/45`). Large objects are split across workers. The scan loop resolves candidates inline; one marker now costs about Boehm's single marker on JsonParsePure and 1.3× on Primes | `parallel_mark.cr`, `collect_mark.cr`; `bench/log/linux/2026-10-06-mark-cost/` |
| M2 | **Partly fixed** on Linux x86_64: crystal-metric, 12 CPUs, 11 trials, % of Boehm's speed (master → branch): Primes 42→100%, JsonParsePure 42→91%, Binarytrees 81→94%, JsonGenerate 105→105%; JsonParseSerializable (88%), JsonParsePull (91%) and Revcomp (84%) are where master was — their fault-bound gap needs the `realloc` page move, which is opt-in because it is unsafe for the stdlib. Peak RSS under Boehm's on every GC-bound row on Linux. Windows x86_64 (12-vCPU VM): 87–114% of Boehm; peak working set above Boehm's on JsonParsePure (1.14×), Knuckeotide (1.73×) and Matmul (1.18×), transient peaks, not retention | `bench/log/linux/2026-10-06-pr-benchmarks/after-review/`; `bench/log/windows/2026-10-06-vm-validation/` |
| M3 | **Fixed**: every loaded shared object's writable data is a root (Linux, macOS, Windows) | `platform/*_roots.cr`; `process_spec/regression/16`, `34` (Linux), `36` (Windows: 20 of 20, control arm collects) |
| M4 | **Fixed**: Boehm's ignore-self finalization order; dangling weak links dropped | `collect_mark.cr`; `process_spec/regression/17`, `20` |
| M8 | **Fixed**: Boehm's `GC_*` C ABI and `lib LibGC`, including `GC_stackbottom`, `GC_remove_roots`, `GC_register_disappearing_link` / `GC_unregister_disappearing_link`, and C-thread registration on Linux, macOS and Windows; `INTEGRATION.md` § Boehm parity lists what still differs | `c_abi.cr`; `process_spec/regression/21`, `25`, `29`, `41`, `47` |
| m1–m6 | **Fixed**: nesting `disable`, honest `prof_stats`, `Crystal.trace :gc`, `free` and `realloc` never raise into C callers, `set_stackbottom(thread)`, `GC.sig_suspend/resume` | `gc_override.cr`; `process_spec/regression/18` |
| m7 | **Mitigated**: one byte of slack on atomic blocks, as under Boehm; the argv patch stays | `heap.cr`; `process_spec/regression/24` |
| m8 | **Fixed**: docs refreshed; `INTEGRATION.md` lists Windows as in scope only, and its Boehm parity table names what differs | `README.md`, `docs/*` |
| m9 | **Fixed**: `rbp`/`x29` captured unmangled | `roots.cr`; `process_spec/regression/15` |
| M5, M6, M7 | **Open**: open races, TSan/fuzzing, knob surface | below |

Two Crystal bugs turned up along the way, both outside gcry: `raises?` is not
a fixpoint (§1, E3), and `String::Builder#to_s` writes one byte past its
buffer (`bench/log/linux/2026-10-05-string-builder-terminator/`). Both have
patches ready for upstream.

Each item has an ID so later work can refer to it. Evidence is either
**observed** (run during this review) or **read** (taken from source or docs
at the cited location). `[INFERENCE]` marks reasoning that was not executed.

---

## 1. Executed: Crystal's own std_spec under gcry

Nothing in the Makefile, CI or docs runs Crystal's `spec/std` or
`spec/compiler` under gcry. `docs/TEST_PLAN.md` §6.3 was closed with a mirror
(`bench/compiler_gc_contract.cr`) and explicitly does not aim for a full
stdlib pass. This review ran it.

### How it was run

```sh
git clone --depth 1 --branch 1.21.0 https://github.com/crystal-lang/crystal /tmp/crystal-1.21
cd /tmp/crystal-1.21
cat > spec/gcry_std_spec.cr <<'EOF'
require "gcry"
module LibGC            # gcry has no GC_size; string_spec calls LibGC.size.
  def self.size(ptr) : UInt64
    0_u64               # makes that one spec fail visibly instead of not compiling
  end
end
require "./std_spec"
EOF
CRYSTAL_PATH=/path/to/gcry/src:/tmp/crystal-1.21/src \
  crystal build -Dgc_none spec/gcry_std_spec.cr -o /tmp/gcry_std_spec
```

### Results

| ID | Finding | Status |
|----|---------|--------|
| **E1** | Full `std_spec` does not compile under gcry. `src/gcry/layout.cr:805` (`register_all_from_reference_subclasses`) expands `register(Array(RecursiveNilableType))` → `Error: undefined constant RecursiveNilableType`. The source is `spec/std/class_spec.cr:21`, `private alias RecursiveNilableType = Array(RecursiveNilableType)?`. | observed |
| **E2** | `spec/std/string_spec.cr:2830` calls `LibGC.size`. gcry has no `GC_size` equivalent: no API returns the usable size of a block. **Fixed 2026-10-05:** `Gcry.usable_size` (base or interior pointer, as Boehm). | observed |
| **E3** | `rescue` does not catch the `ArgumentError` from `String.new(Pointer(UInt8).null, 3)` under gcry (details below). | observed |
| **E4** | The full std_spec binary could not run on this host: `symbol lookup error: undefined symbol: __libc_start_main, version <garbage>`. The **Boehm** build of the same suite fails the same way, so this is a toolchain problem (GNU ld 2.46 on this very large binary), not gcry. | observed, not gcry |

The full suite could not run (E4), so a GC-relevant subset was built against
both backends:

```
spec/std/{gc,weak_ref,reference,string,string_builder,array,hash,deque,set,
          channel,mutex,wait_group,process,thread,regex}_spec.cr
spec/std/io/memory_spec.cr
spec/std/{json,fiber,thread,compress,big,http}/**
```

To make it compile, the patched copy had the `Gcry.register_layouts` /
`register_scan_caps` calls removed from `GC.init` (the E1 workaround) and
used the `LibGC.size` shim above.

| Backend | Examples | Failures | Errors |
|---------|---------:|---------:|-------:|
| Boehm | 4364 | 0 | 0 |
| gcry | 4364 | 1 (E2 shim, expected) | **1 (E3)** |
| gcry, `GCRY_STRESS=1 GCRY_STRESS_EVERY=256` | 4364 | 1 (E2) | 1 (E3) |

No crash, hang or memory corruption showed up in the subset, stress mode
included.

**After item 1 (2026-10-05).**

- **Full `std_spec`.** It compiles against unmodified gcry. Linking it still
  hits E4 on this host.
- **The same subset.** It ran with the shim `LibGC.size(p) =
  Gcry.usable_size(p.as(Void*))`:

| Backend | Examples | Failures | Errors |
|---------|---------:|---------:|-------:|
| gcry | 4364 | 0 | 0 |
| gcry, `GCRY_STRESS=1 GCRY_STRESS_EVERY=256` | 4364 | 0 | 0 |

**After item 2 (2026-10-05): the whole suite.** `ci/std-spec.sh` takes
`spec/std` from the compiler's own commit. It builds the suite in chunks to
stay clear of E4 (four here), and runs it. It finds no failure gcry causes:

| Compiler | Backend | Examples | Failures | Errors | Pending |
|----------|---------|---------:|---------:|-------:|--------:|
| 1.21.0 | Boehm | 18 054 | 0 | 0 | 30 |
| 1.21.0 | gcry | 18 054 | 0 | 0 | 30 |
| 1.21.0 | gcry, `GCRY_STRESS=1 GCRY_STRESS_EVERY=256` | 18 054 | 0* | 0 | 30 |
| 1.21.0 | gcry, `GCRY_SOUND=1` | 18 054 | 0 | 0 | 30 |
| 1.21.1 | gcry | 18 068 | 0 | 0 | 30 |

\*0 unexpected failures. One example is allowlisted for the stress rerun
(`ci/std-spec-stress-allow.txt`): `spec/std/log/builder_spec.cr:230` reads
Log objects held only by WeakRefs after a collection may have run, so it can
fail by design; it failed 1 of 5 255 in CI run 37592592091.

CI job `std-spec` runs the suite on Linux x86_64: on 1.21.0, including a
`GCRY_STRESS=1` rerun with that allowlist, on `latest`, and on `nightly`,
which is allowed to fail.

### E1: the private recursive alias that breaks compilation

Minimal reproducer (does not compile with `-Dgc_none`):

```crystal
require "gcry"
private alias R = Array(R)?
x = [nil] of R
```

- **Scope.** A type fails when its name, spelled from `layout.cr`, does not
  resolve: a private *recursive* alias (a non-recursive one stringifies to
  its target), or a class inside a private module. A public recursive alias
  compiles.
- **Cause.** The macro walks `Reference.all_subclasses` and emits type names.
- **Why it is dead weight.** `GC.init` calls `Gcry.register_layouts` behind a
  *runtime* env check (`gc_override.cr:217-219`, `GCRY_AUTO_LAYOUTS`). The
  macro is therefore compiled into every program, even though the mark has
  read no layout table since 2026-10-04 (`docs/API.md`; commit `0671a0c`).
  `register_scan_caps` (`GCRY_SCAN_CAPS`) has the same shape.
- **Status: fixed (2026-10-05).** Both macros skip a type unless
  `parse_type(t.stringify).resolve?` is the type itself. Whether layout
  registration should stay at all is still the ROADMAP's open question. Gate:
  `process_spec/regression/12_private_type_registration_spec.cr`. Before the
  fix it does not compile.

### E3: an exception that `rescue` does not catch

```crystal
require "gcry"
begin
  String.new(Pointer(UInt8).null, 3)
rescue e
  puts "ok"
end
```

| Build | Result |
|-------|--------|
| Boehm | `ok` |
| `-Dgc_none` without gcry | `ok` |
| `-Dgc_none` + gcry (debug or `--release`) | `Unhandled exception: Cannot create a string with a null pointer and a non-zero (3) bytesize (ArgumentError)` |

- **What the IR shows.** `--emit llvm-ir --single-module`: under gcry the call
  in `__crystal_main` is a plain `call ptr @"*String::new<Pointer(UInt8), Int32>:String"`
  with no landing pad. Without gcry it is `invoke`. The compiler emits `call`
  when `target_def.raises?` is false (`compiler/crystal/codegen/call.cr:511`).
  `raises?` is propagated once per def while the cleanup transformer walks
  call targets (`semantic/cleanup_transformer.cr:596-610`).
- **How far it reaches.** 14 other stdlib raises (`"abc".to_i`, `[1][5]`,
  `Hash#[]`, overflow, `not_nil!`, `File.read`, `JSON.parse`, `Int32.new`,
  and others) are rescued correctly under gcry. The only one seen to fail is
  `String.new(Pointer(UInt8), Int32)`.
- **Root cause: a Crystal compiler bug that Boehm builds hit too.**
  - **Mechanism.** `raises?` is copied from callee to caller once, when the
    cleanup pass reaches the call. A callee reached again through a call
    cycle is still being transformed and may not yet raise. Its callers stay
    marked as not raising for good.
  - **Stock repro.** With stock 1.21.0 and Boehm,
    `begin 5.clamp(...3) rescue … end` is unhandled. A stdlib-free program
    reproduces it too.
  - **What gcry adds.** gcry's `GC.malloc*` bodies are Crystal, so the stdlib
    reaches the collector and comes back. The traced cycle is
    `String.new(chars, bytesize, size)` → message interpolation →
    `String::Builder` → `GC.malloc_atomic` → gcry →
    `RuntimeError.from_os_error` → `Errno#message` → `String.new(Slice)` →
    `String.new(Pointer(UInt8), Int32)`. On a small program the instrumented
    compiler counts 15 stranded callers under Boehm and 29 under gcry
    (`bench/log/linux/2026-10-05-raises-cycle/FINDINGS.md`).
- **Status (2026-10-05).**
  - **gcry workaround.** `src/gcry/crystal_raises_compat.cr` reopens that
    `String.new` with `@[Raises]`. Gate:
    `process_spec/regression/13_rescue_string_new_null_spec.cr`.
  - **Compiler fix.** It propagates the flag to a fixpoint and adds a codegen
    spec: `bench/log/linux/2026-10-05-raises-cycle/crystal-raises-fixpoint.patch`.
    With it, all three repros rescue and `exception_spec.cr` passes 73/73.
    It is not upstream yet.
  - **Why it still matters for a default.** Until the compiler fix lands, a
    different program can strand a different method.

---

## 2. Blockers

§2–§4 record the review as it was on 2026-10-04. The status table at the
top supersedes them.

| ID | Gap | Evidence |
|----|-----|----------|
| **B1** | **Defaults are not sound.** Under multi-mutator STW a parked fiber whose SP is unproven is scanned only within `stw_multi_stack_lag` = 256 KiB of its stack top, and a thread whose SP sits on a pool fiber gets only the top `stw_multi_pthread_lag` = 256 KiB of its pthread stack; a live pointer deeper than the lag is never seen. The parked-fiber-from-saved-SP path relies on runtime invariants the collector does not check (swapcontext store order; SYSMON/idle never running user fibers). `GCRY_SOUND=1` is opt-in, although the README measures its cost as ~0 at EC1 and a small pause increase with more threads. | read: `collect_scan.cr:1055,1071,1108`; `docs/SOUND-DEFAULTS.md` knob table and "How to read this" |
| **B2** | **Live-object loss keeps turning up under default settings.** Union-buffer UAF (`[Unreleased]`), macOS FP/SIMD-register roots (0.33.0), static-root `type_id` gate (2026-09-29). The Thread UAF family is still open, covered only by a spin budget's timing. | read: `CHANGELOG.md` `[Unreleased]`, 0.33.0; `platform/thread_staging.cr:243-268`; `docs/HARDENING.md` "open Thread use-after-free" |
| **B3** | **Parallel ExecutionContext is not a supported default.** The compiler itself runs `Fiber::ExecutionContext.default.resize(default_workers_count)`. gcry ships Parallel only as opt-in with TLAB off; `GCRY_TLAB` / `GCRY_PARALLEL_RELEASE` are unsupported; Parallel-specific UAF/SEGV reports are still open. | read: `compiler/crystal.cr:11-12`; `docs/POLICY.md` Threading; `docs/INTEGRATION.md` Scope; `ROADMAP.md` nested_spawn_uaf, 2026-08-10 soak SEGV |
| **B4** | **No compiler self-host and no interpreter story.** The compiler has never been built or run with gcry. `crystal i` resolves `GC_*` symbols from the host compiler binary, and gcry exports no `GC_*` C ABI (only `gcry_register_finalizer` (win32), `gcry_mark_worker_main`, `gcry_stw_watchdog_main`). | read: `compiler/crystal/interpreter/context.cr:441-460`; grep of `src/` |
| **B5** | **Platforms.** No platform layer for FreeBSD, OpenBSD, NetBSD, DragonFly or Solaris (`collect.cr:1-20` has no `else`). Android is untested, and its fast path uses `@[ThreadLocal]`, which Crystal avoids there. 32-bit (i386, armhf) compiles with no error but scans roots in 8-byte strides and never installs the STW SP-capture handler. A per-platform rollout ("default on Linux first", ROADMAP Phase 4) would scope this down. | read: `roots.cr:285-289,329-333`; `platform/linux_stw.cr:52-56,610-613`; `platform/os.cr:3-6`; `bitmap_alloc.cr:174-179` |
| **B6** | **No upstream-grade runtime interface.** gcry reads private stdlib ivars (`Fiber@stack`, `@context.stack_top`, `Thread@current_fiber/@main_fiber/@name/@system_handle`, ExecutionContext `@schedulers/@global_queue`, `Fiber@@fibers.@mutex`), keys the monitor exemption on `Thread#name == "SYSMON"`, reopens `Fiber::ExecutionContext::Monitor`, and gates thread staging on `flag?(:gc_none)` (a future `-Dgc_gcry` would compile it out silently). Every gcry gate pins Crystal 1.21.0. Only `std-spec` also runs `latest` and `nightly`, so a stdlib rename that silently compiles a root source out is caught only if spec/std happens to exercise it. | read: `collect_stw.cr:759,992`; `collect_scan.cr:360-424,1131-1177`; `monitor_gate.cr:230`; `gc_override.cr:1695-1768`; `.github/workflows/ci.yml:79-92` |
| **B7** | **Crystal's own suites are not in CI.** See §1. At review time std_spec did not compile (E1) and one exception was miscompiled (E3), and compiler_spec had never been tried. All of that is closed as of 2026-10-06 on Linux x86_64: **std_spec passes in full in CI** (`std-spec` job), and so does compiler_spec, built by the host compiler with gcry linked in and run with gcry as the process GC (`compiler-gcry` job; see the status table). macOS and Windows still do not run them. | observed |

## 3. Major gaps

| ID | Gap | Evidence |
|----|-----|----------|
| **M1** | **Mark cost and parallel mark.** Serial mark is ~2.6× Boehm's single marker on a large pointer heap, ~10× its default parallel marker. As of 2026-10-05, `GCRY_PARALLEL_MARK=2` with the 32 MiB floor gains 8–16 points on GC-heavy rows for 2–42% more CPU; 4 workers win only on arm64. It is not a default yet (proposed default: `min(2, CPUs−1)`). | read: `ROADMAP.md` "Per-collection mark cost"; `bench/log/linux/2026-10-05-parallel-mark-default/FINDINGS.md` |
| **M2** | **Allocation-storm throughput.** crystal-metric, speed as % of Boehm (ubuntu-latest, default): Primes 38%, JsonParsePure 47%, JsonGenerate 53%, JsonParseSerializable 68%, Revcomp 79%, Binarytrees 83%, RegexDna 91%. Peak RSS is mostly *under* Boehm (0.43–0.89×). `GCRY_THRESHOLD_MAX=256 MiB` buys +8–23 points at ≤1.1× Boehm RSS. That RSS budget is undecided. | read: `bench/log/linux/2026-10-05-rss-budget-vs-boehm/FINDINGS.md` |
| **M3** | **Shared-library static data is not scanned.** Roots come from the main executable's writable segments only (Darwin: image 0; Windows: main module). Boehm scans loaded libraries. Crystal code in a `.so`, or a C library holding GC pointers in its globals, loses roots. | read: `platform/linux_roots.cr:8-11,103-118`; `platform/darwin_roots.cr`; `docs/WINDOWS.md` DLL globals |
| **M4** | **Unordered finalization.** All unmarked finalizables are enqueued in one pass. Boehm's `register_finalizer_ignore_self` is topologically ordered, so close/free order can differ. | read: `collect_mark.cr:778-805`; stdlib `gc/boehm.cr:334-347` |
| **M5** | **Open races and liveness issues.** Chunk index/list drift ("the race is open"); a large chunk released with a live block (`dormant_flush`, unreproduced); an `@index_lock` holder could wedge the sweep; Windows collector-lock livelock (harness-mitigated); Darwin Intel counter loss; O(n) large free; large `realloc` growth. | read: `ROADMAP.md` open items |
| **M6** | **Verification depth.** No TSan and no coverage-guided fuzzer. ASan covers one spec, valgrind 4 samples. No production dogfood. ~305 unit examples run the *library* heap under Boehm; the real process GC gets `process_spec/` (~20 examples + regression files) plus `make` gates. | read: `ci/asan_check.py`; `ROADMAP.md` "Production dogfood", "Security / fuzzing"; `docs/INTEGRATION.md` "Two test modes" |
| **M7** | **Review and maintenance surface.** ~38k LOC; ~210 `GCRY_*` knobs parsed in `GC.init`, several "research only" or "restores a defect"; audits, tripwires and experiments are compiled into the product (`src/gcry.cr:36-47`); three heap representations (headerless, header, freelist). Single maintainer, about 10 weeks old, 34 releases. | read: `docs/HARDENING.md` env table; `src/gcry.cr` |
| **M8** | **`GC_*` ecosystem ABI.** Shards that bind `LibGC` directly (as std_spec does, E2) have nothing to link against. `Gcry.usable_size` covers `GC_size` at the Crystal level only. | observed (E2); read: `src/` exports |

## 4. Minor gaps

| ID | Gap | Evidence |
|----|-----|----------|
| m1 | `GC.disable` is a boolean, not a counter: `disable; disable; enable` re-enables collection (Boehm nests). | read: `gc_override.cr:1546-1555` |
| m2 | `GC.prof_stats`: `non_gc_bytes` and `markers_m1` are 0; `obtained_from_os_bytes` is approximated. | read: `gc_override.cr:1625-1658` |
| m3 | No `Crystal.trace :gc` events (both `gc/boehm` and `gc/none` emit them); gcry has its own `GCRY_TRACE`. | read: grep of `src/` |
| m4 | `GC.free` raises on a stale in-span pointer, which unwinds through C frames when zlib or GMP call it as their allocator callback. Explicitly freeing a finalizable object runs its finalizer (Boehm does not). | read: `gc_override.cr:1557-1568`; `finalizer.cr:183-231` |
| m5 | `GC.set_stackbottom(thread, ptr)` ignores `thread` and sets one global. | read: `gc_override.cr:1787-1793` |
| m6 | `GC.sig_suspend` / `sig_resume` are not defined; gcry relies on hard-coding the same values as Crystal's private constants. | read: `platform/linux_stw.cr:19-25` |
| m7 | stdlib argv allocation relies on Boehm's size rounding; gcry monkey-patches it (`crystal_process_compat.cr`). It needs an upstream stdlib fix. | read |
| m8 | Docs disagree: `INTEGRATION.md` lists Windows as "Out" and then documents it as shipped; `HARDENING.md` header says "layout scan on"; `COMPARISON.md` is a 0.17.0 snapshot; README's Kemal `/` row is a v0.16 carry. | read |
| m9 | `[INFERENCE]` On x86_64 the collecting thread's registers are captured with glibc `setjmp`, which mangles `rbp`, and the clobber list omits `rbp`. Commit `d15b0ea` (2026-10-05) touched register scrubbing; not re-checked. | read: `roots.cr:113-189` |

---

## 5. Suggested order

1. **E1, E2, E3: done 2026-10-05.**
   - E1: the layout macros skip types this file cannot spell.
   - E2: `Gcry.usable_size`.
   - E3: `crystal_raises_compat.cr`, plus a compiler patch in
     `bench/log/linux/2026-10-05-raises-cycle/`.
   - Still open: filing the compiler issue/PR upstream.
2. **B7: done 2026-10-05.**
   - The CI job `std-spec` runs `spec/std` on 1.21.0 (with a
     `GCRY_STRESS=1` rerun), on `latest` and on `nightly`.
   - The job `compiler-gcry` builds the compiler with gcry and runs
     `compiler_spec`.
3. **B1: done.** The sound profile is the default.
4. **B3 / M1: mostly done.**
   - Parallel mark is on by default, and the compiler's Parallel EC passes
     its suite.
   - TLAB and `GCRY_PARALLEL_RELEASE` remain research arms.
5. **B4: done.** The compiler self-hosts with gcry. `crystal i` binds gcry's
   `GC_*` exports (`c_abi.cr`), so the interpreter does not need Boehm.
6. **B6: proposed.** `docs/RFC-GC-BACKEND.md` covers `src/gc/gcry.cr`,
   `-Dgc_gcry`, and runtime↔GC hooks to replace the ivar reads and the
   Monitor reopen. It proposes Linux first.
7. **Open:**
   - M2: the mark's per-thread cost, and page reuse between large and small
     objects.
   - M5: races.
   - M6: TSan and fuzzing.
   - M7: knob and research-code reduction.
   - Upstream: filing the three stdlib/compiler fixes.

## 6. Limits of this review

- std_spec ran in full on Linux x86_64 with Crystal 1.21.0, 1.21.1 and
  nightly.
- compiler_spec and `crystal i` ran on Linux x86_64 only.
- macOS and Windows run gcry's own gates in CI, but not Crystal's suites.
- Most "read" items come from source and doc reading at the cited lines;
  they were not reproduced.
