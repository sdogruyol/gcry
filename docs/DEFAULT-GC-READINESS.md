# Default-GC readiness review

What gcry is missing to become Crystal's **default** collector, in place of
Boehm in `crystal-lang/crystal`. Reviewed on 2026-10-04 against gcry 0.34.0
(`6650b80`), Crystal 1.21.0 (`57cf7da50`), Linux x86_64. The perf rows were
refreshed on 2026-10-05; the status table was last updated on 2026-10-12,
after PR #47 and #48.

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
| B3 | **Mostly closed**: parallel mark on by default; the compiler (Parallel EC at CPU count, mt codegen) builds, self-hosts and passes `compiler_spec` under gcry. TLAB stays an unsupported research arm | `gc_override.cr`; `ci/compiler-spec.sh` |
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
| m8 | **Fixed**: docs refreshed; `INTEGRATION.md` lists Windows as in scope only, and its Boehm parity table names what differs; `COMPARISON.md` describes the current tree | `README.md`, `docs/*` |
| m9 | **Fixed**: `rbp`/`x29` captured unmangled | `roots.cr`; `process_spec/regression/15` |
| M5 | **Partly closed** (readiness-2): chunk index/list drift is closed (the relink store splices back what was mapped during the walk, and a `GC.free` trim no longer detaches during it; `make chunk-list-drift` cap 0); the Windows collector-lock livelock is fixed in the product (the collection section hands over in arrival order and `GC.collect` is answered by any full collection that began after it; the roots lock lets waiting mutators in ahead of a stop; `process_spec/regression/50`). Counter loss closed (0.36.0): the macos-15-intel sighting was the checker reading a runtime thread's birth allocation in flight (`69`); a real lost decrement, `live_objects_sub` saturating at zero, is fixed (`68`); `make counter-loss` has a red arm that is actually plain and runs on Darwin again. Still open: `dormant_flush` (unreproduced), the `@index_lock` holder in a stop (policy), O(n) single large unlink. Large `realloc` grows in place since 0.36.0 (`66`) | `collect_sweep.cr`, `collect.cr`, `roots_lock.cr`; `ROADMAP.md` |
| M6 | **Open**: TSan/fuzzing | §2–4 below; `ROADMAP.md` |
| M7 | **Partly closed** (0.36.0): `Gcry::Layout` and its registration API removed (6 knobs, −2 200 lines), 22 research-only or defect-restoring knobs no gate set (−1 140 lines), and the `GCRY_THREAD_LIST_TRIPWIRE` instrument family, whose `0x18` crash (`index_insert_locked`'s publication order) was fixed on 2026-08-27 (−530 lines). Still open: the research arms no gate sets, e.g. `GCRY_DYING_GREG_DUMP` | `CHANGELOG.md` `[Unreleased]` |
| D1 | **Fixed** (PR #47, #48; not in the 2026-10-04 review): 11 defects on the default path. #47: a `Thread`'s birth root armed after its thread could end, `EINTR` and `errno` from the stop signals, stacks deeper than 64 MiB, the probe pipe under fd pressure, a parked finalizer blocking collection, a forked child's first stop. #48: chunk-index OOM hang, `realloc` shrink-then-grow stale bytes, `GC.free` of finalizers and of disappearing links, `GC.stop_world` without the collection's locks, release of a chunk holding an allocation cursor. Since then the stop calls no C heap function on Windows and macOS | `CHANGELOG.md` `[Unreleased]`; `process_spec/regression/52`–`63` |

Two Crystal bugs turned up along the way, both outside gcry: `raises?` is not
a fixpoint (§1, E3), and `String::Builder#to_s` writes one byte past its
buffer (`bench/log/linux/2026-10-05-string-builder-terminator/`). Both have
patches ready, re-verified on Crystal master `39f3f4d`, and are reported
upstream as crystal-lang/crystal#17644 and crystal-lang/crystal#17645 (2026-10-14).

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
- **Since 0.36.0** the registration is gone with `Gcry::Layout`, and with it
  the macros and spec 12.

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
    Reported upstream as crystal-lang/crystal#17644 (2026-10-14).
  - **Why it still matters for a default.** Until the compiler fix lands, a
    different program can strand a different method.

---

## 2–4. Blockers, major and minor gaps (historical, as of 2026-10-04)

The full gap tables as reviewed on 2026-10-04, with their evidence, are in
this file's git history (`git show 828b95c:docs/DEFAULT-GC-READINESS.md`,
the last commit before they were collapsed). The status table at the top supersedes
them. One line per ID, as it read then:

- **B1** defaults were not root-complete (STW stack lags 256 KiB).
- **B2** live-object loss kept turning up under default settings.
- **B3** a Parallel ExecutionContext was not a supported default.
- **B4** no compiler self-host and no `GC_*` C ABI for `crystal i`.
- **B5** no platform layer or compile-time refusal for other targets.
- **B6** no upstream-grade runtime interface (private stdlib ivars).
- **B7** Crystal's own suites were not in CI.
- **M1** serial mark ~2.6× Boehm's single marker; parallel mark opt-in.
- **M2** allocation-storm throughput (Primes 38% of Boehm's speed).
- **M3** shared-library static data was not scanned.
- **M4** unordered finalization.
- **M5** open races and liveness issues.
- **M6** verification depth: no TSan, no coverage-guided fuzzer.
- **M7** review and maintenance surface (~210 `GCRY_*` knobs).
- **M8** no Boehm `GC_*` ecosystem ABI.
- **m1–m9** `GC.disable` did not nest; `prof_stats` approximated; no
  `Crystal.trace :gc`; `GC.free` raised into C callers;
  `set_stackbottom(thread)` ignored the thread; no `GC.sig_suspend/resume`;
  argv relied on Boehm's rounding; docs disagreed; `rbp` captured mangled.

---

## 5. Suggested order

1. **E1, E2, E3: done 2026-10-05.**
   - E1: the layout macros skip types this file cannot spell.
   - E2: `Gcry.usable_size`.
   - E3: `crystal_raises_compat.cr`, plus a compiler patch in
     `bench/log/linux/2026-10-05-raises-cycle/`.
   - Reported upstream as crystal-lang/crystal#17644; the PR waits on it.
2. **B7: done 2026-10-05.**
   - The CI job `std-spec` runs `spec/std` on 1.21.0 (with a
     `GCRY_STRESS=1` rerun), on `latest` and on `nightly`.
   - The job `compiler-gcry` builds the compiler with gcry and runs
     `compiler_spec`.
3. **B1: done.** The sound profile is the default.
4. **B3 / M1: mostly done.**
   - Parallel mark is on by default, and the compiler's Parallel EC passes
     its suite.
   - TLAB remains a research arm.
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
   - Upstream: crystal-lang/crystal#17644 and crystal-lang/crystal#17645 are
     filed; the PRs wait on them. The `argv` terminator was fixed upstream
     by crystal-lang/crystal#17184, released in 1.22.0.

## 6. Limits of this review

- std_spec ran in full on Linux x86_64 with Crystal 1.21.0, 1.21.1 and
  nightly.
- compiler_spec and `crystal i` ran on Linux x86_64 only.
- macOS and Windows run gcry's own gates in CI, but not Crystal's suites.
- Most "read" items come from source and doc reading at the cited lines;
  they were not reproduced.
