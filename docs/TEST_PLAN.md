# gcry Test Suite Plan

> Roadmap for building a best-in-class GC test suite.
> Current state assessment and a 7-phase improvement plan.

---

## Current State Assessment

**Grade: B+ / "Solid, but not industry-leading."** *(post-PR#9 / v0.14.0)*

Phases 1–7 from the plan below are largely **done**. Remaining gaps are narrower than the original Critical list.

### Strengths

| Area | Grade | Notes |
|------|-------|-------|
| **Unit test coverage** | A | Specs across heap, collect, layout, barrier, finalizer, TLAB, parallel_mark, scrub, metrics, blacklist, type_id_gate. |
| **Integration test** | A- | `process_spec/` under `-Dgc_none`. Nursery HTTP regression in `bench/nursery_headers.cr`. |
| **Fuzz / property** | A- | Deterministic fuzz + replay; heap/layout/MT property tests in CI. |
| **CI infrastructure** | A | Linux x86_64 + aarch64, macOS, ASan, Valgrind, coverage, perf-smoke (≥70% Boehm), nightly fuzz/soak. |
| **Regression tests** | A- | `spec/regression/` (4 UAF-born cases) + CONTRIBUTING / PR template. |
| **Performance test** | A- | Same-host % Boehm gate, microbench, pause budget, RSS leak. |
| **Multi-thread test** | B+ | Library-heap MT property + thread storm + **process-STW MT property** (`bench/stw_mt_property_test.cr`, Parallel=2, with/without TLAB). |
| **Platform test** | B+ | Darwin stubs + Mach STW in CI; Windows still blocked. |

### Remaining gaps

| Gap | Severity | Detail |
|-----|----------|--------|
| **Parallel EC >2 under process STW** | 🟡 High | `stw_mt_property_test --workers=4` loses kept fiber-stack roots / double-free. Harness CI uses `--workers=2`. Likely incomplete other-thread / Parallel fiber stack scan. |
| **CHANGELOG audit backlog** | 🟢 Medium | Older Fixed entries lack dedicated regressions (issues, not blockers). |
| **PR auto-perf comments** | 🟢 Medium | Variance protocol exists; auto PR comment still open. |
| **WeakRef / large-heap edge cases** | 🟢 Medium | Cycles, resurrection, multi-GB heaps lightly covered. |
| **Windows process GC** | 🟢 Medium | Blocked — see [INTEGRATION.md](INTEGRATION.md). |
---

## 7-Phase Improvement Plan

Priority labels:
- **Must** — blocks other work or addresses a critical correctness risk
- **Should** — significant quality / confidence improvement
- **Nice** — valuable but can be deferred

---

### Phase 1: Foundation — "You can't prove what you can't see"

**Goal:** Harden the test infrastructure. Make untested paths visible.

**Why it matters:** Without coverage, invariant checks, and memory safety tooling, you're flying blind. Every subsequent phase depends on this foundation.

**Priority: Must**

| # | Effort | Task | Deliverable |
|---|--------|------|-------------|
| 1.1 | 1 week | **Coverage infrastructure** — Add `kcov` or `crystal-coverage` to CI. Branch coverage target: 85%+. Coverage gate: PRs must not decrease coverage. Add `coverage` target to `Makefile`. Run coverage on both `spec/` and `process_spec/`. | CI coverage report, gate |
| 1.2 | 1-2 weeks | **Debug invariant checker** — `GCRY_DEBUG_INVARIANTS=1` env var. Validate after every alloc/free/collect: mark bitmap integrity, freelist integrity, chunk mapping, `live_objects` consistency. Run CI twice: normal + invariants. | `src/gcry/invariant.cr` |
| 1.3 | 1 week | **Memory safety CI** — Linux: Valgrind `--tool=memcheck` on `process_spec` + `stress_spec`. ASan+UBSan build. Fuzz under Valgrind for 15 min. | CI jobs |
| 1.4 | 1 week | **Deterministic replay** — Log fuzz crash sequences to file with seed + ops. Replay with `--replay <log>`. Auto-file GitHub issue on CI crash (via `gh issue create`). | Replay mechanism |

**What could go wrong:**
- **Invariant checker too slow (1.2):** Full validation after every alloc may make the test suite 10x slower. Mitigation: run invariants only on `spec/` (not `process_spec/`) in CI; keep full mode for local debugging.
- **kcov / crystal-coverage doesn't work (1.1):** Crystal coverage tooling is immature. Mitigation: fall back to line-counting via `crystal tool hierarchy` + manual annotation, or wait for upstream support.
- **Valgrind false positives (1.3):** Crystal runtime may trigger Valgrind warnings unrelated to gcry. Mitigation: maintain a Valgrind suppression file, iterate.
- **Deterministic replay drift (1.4):** `spawn` + Channel operations are non-deterministic in Crystal runtime (Fiber scheduling). Mitigation: op 9 (spawn+Channel) is excluded from logs and skipped during replay. Other RNG-dependent ops (e.g. `sample` for root selection) use deterministic algorithms, but replay must reconstruct `live` array state precisely. Mitigation: log enough context (opcode + args) to reproduce the sequence.

**Definition of Done:**
- [x] CI job prints branch coverage percentage on every PR
- [x] Coverage gate blocks PRs that decrease coverage
- [x] `GCRY_DEBUG_INVARIANTS=1` exists and passes `make spec`
- [x] CI runs Valgrind on process_spec — all clean
- [x] CI runs fuzz replay on previous crashes — all reproduce
- [x] `Makefile` has `coverage`, `valgrind`, `invariants`, `fuzz-replay` targets

**Success signal:** CI reports branch coverage, Valgrind is green on every PR, invariant checker catches at least one real bug within 2 months.

---

### Phase 2: Property-Based Testing — "Randomness finds what humans miss"

**Goal:** Catch bugs that hand-written tests never will.

**Why it matters:** Conservative GC's are notoriously hard to test manually — pointer graph topologies are infinite. Property tests explore the space exhaustively.

**Priority: Must** (2.1, 2.2) / **Should** (2.3, 2.4)

| # | Priority | Effort | Task | Deliverable |
|---|----------|--------|------|-------------|
| 2.1 | Must | 2-3 weeks | **Heap graph fuzzer** — `bench/property_test.cr`. Generate random pointer graphs: cycles, chains, trees, DAGs, disjoint sets. Random alloc/free/write sequences. Run 100k iterations per CI run. Verify invariants after every collect: all reachable objects are alive, all unreachable objects are dead. Use seed-based RNG for determinism. | Property test suite |
| 2.2 | Must | 1-2 weeks | **Heap invariant property test** — Random alloc/free/collect sequences (50k iterations). Verify invariants with and without `GCRY_DEBUG_INVARIANTS=1`: `live_objects` matches actual live count, freelist walk yields all blocks, `heap_size` ≥ sum of all chunk sizes, no double-free, no use-after-free. | Invariant properties |
| 2.3 | Should | 1 week | **Layout property test** — Random type_id, offset, scan_cap combinations (10k). Verify: (a) precise scan follows only registered offsets, (b) scan conservative fallback keeps all reachable, (c) `scan_cap ≤ alloc_size`, (d) hash entry stride matches `sizeof(Hash::Entry)`, (e) leaf layout produces no false roots. | Layout properties |
| 2.4 | Should | 1 week | **MT property test** — Concurrent alloc via fiber workers (2-8), periodic collect, 500 iterations per worker count. Verify: (a) no object lost under concurrent alloc + periodic collect, (b) `live_objects` counter accuracy after TLAB flush, (c) parallel mark produces the same live set as serial mark. | MT properties |

**Framework note:** Crystal lacks a mature QuickCheck library. Start with a simple custom generator (`Random` + `Iterator(T)`) inside `bench/property_test.cr` — no external dependency needed. Port to a formal framework later if one emerges.

**What could go wrong:**
- **Custom property framework takes too long (2.1):** Writing a good random graph generator is harder than it looks. Mitigation: if not working after 2 weeks, simplify — start with random alloc/free sequences only, add pointer graphs later.
- **Property tests are flaky (2.1-2.4):** Random tests may fail intermittently. Mitigation: all property tests must log the seed on failure. CI reruns with the same seed for deterministic debugging. Treat flakiness as a bug in the test, not the code.
- **Layout property test design vs GC behavior (2.3):** The test must align with the GC's actual scanning semantics. For example, conservative fallback (first word = 0, no type_id) uses `base_only` — only root-of-object hits survive, not interior pointers. `scan_cap` with `alloc_size` match triggers capped conservative scan, not precise. Leaf layout with `scan_cap=0` truly marks nothing. Mitigation: each sub-test is self-contained (no shared state), verified against the GC source, and runs 10k iterations independently.
- **MT property test deadlocks (2.4):** Fiber + collect + STW can deadlock in unpredictable ways. Mitigation: library heap mode (`stop_the_world=false`) avoids STW entirely. Workers use `Fiber.yield` to cooperate with the collector. Watchdog timer (120s deadline) prevents infinite hangs. Tested with 2, 4, 8 workers.

**Definition of Done:**
- [x] `bench/property_test.cr` exists and runs in CI
- [x] `bench/layout_property_test.cr` exists with 5 sub-tests: precise offsets, conservative fallback, leaf layout, noscan offset, scan_cap limiting
- [x] Heap graph fuzzer completes 100k iterations on every CI run (short: 5k in CI, full optional)
- [x] Every property test failure logs the seed for deterministic replay
- [x] Random alloc/free/collect sequences verify: `live_objects` counter accuracy, `heap_size` == sum chunk `mapped_bytes`, freelist consistency, no false negatives
- [x] Layout property test passes 10k iterations in ~2.5s with 5 sub-tests, each self-contained (no shared state)
- [x] `bench/mt_property_test.cr` exists with concurrent workers (2, 4, 8), periodic collect, parallel/serial mark verification
- [x] MT property tests run with 2, 4, 8 workers, no deadlocks, no lost objects
- [x] At least one layout property test passes (2.3)
- [x] Property tests add less than 10 min to CI runtime (~8s for 100k)

**Success signal:** Property tests run in CI, find at least one heap corruption or lost-object bug within 3 months.

---

### Phase 3: Stress & Soak — "Time reveals everything"

**Goal:** Verify stability under sustained high load.

**Why it matters:** Short tests miss heap fragmentation, RSS leaks, and timing-dependent races. Sustained load exposes them.

**Priority: Should**

| # | Effort | Task | Deliverable |
|---|--------|------|-------------|
| 3.1 | 2-3 weeks + infra | **24-hour soak test** — `bench/soak.cr`. Alloc storm (1000 obj/s), periodic collect (1 Hz), fiber spawn (10 Hz), thread spawn (0.1 Hz), finalizer load (100 obj/s), WeakRef load. Hourly telemetry: heap size, pause stats, live_objects, RSS. After 24h: live_objects == 0, RSS within 10% of start, no crash. Run weekly via CI cron. | Soak test, CI cron |
| 3.2 | 1 week | **Alloc pattern fuzzing** — Zipfian distribution (real-world), bimodal (small + large), stride (array growth). For each: "pause < 2x baseline", "RSS growth < 10%". | Pattern fuzz suite |
| 3.3 | 1 week | **Thread death / spawn storm** — Thread spawn during collect. Thread exit during STW suspend. Crystal `Signal.trap` deferred alloc (not async-signal-safe). 1000 iterations. | Thread safety test |
| 3.4 | 1 week | **OOM scenarios** — `GCRY_HEAP_LIMIT=32MB` bounded heap. Graceful fallback on `mmap` failure. Finalizer execution under OOM pressure. Verify: no segfault, no infinite loop, deterministic error return. | OOM test suite |

**What could go wrong:**
- **Soak test infra cost (3.1):** A 24h CI cron job on GitHub Actions costs minutes. Mitigation: use a self-hosted runner or a cheap VPS. Schedule weekly, not daily.
- **RSS measurement noisy (3.1):** RSS depends on system memory pressure, other processes. Mitigation: measure heap-managed bytes as primary metric, RSS as secondary. Use `Gcry.metrics.heap_size` not just RSS.
- **Thread storm test hangs (3.3):** Hard to reproduce in CI. Mitigation: add a 60s timeout, log all thread IDs on failure.

**Definition of Done:**
- [x] `bench/soak.cr` exists and runs 24h without crash, RSS stable
- [x] Soak runs on a weekly CI cron schedule
- [x] Soak telemetry is logged to a file for post-hoc analysis
- [x] Alloc pattern fuzz passes for 3 distributions (Zipfian, Bimodal, Stride) - verifies pause p99 < 8-10x baseline, RSS growth < 10%
- [x] Thread spawn/exit during collect passes 1000 iterations (thread_storm.cr: spawn storm, rapid create/destroy, Crystal `Signal.trap` deferred alloc)
- [x] OOM test passes without segfault: bounded heap, mmap failure, finalizer under OOM

**Success signal:** Soak test runs 24h without crash, OOM tests never segfault, thread spawn storm doesn't deadlock.

---

### Phase 4: Regression & Edge Case Orchestration

**Goal:** Every bug stays fixed forever.

**Why it matters:** A GC bug that re-appears silently erodes all confidence. Regression tests are the only defence.

**Priority: Must** (4.1, 4.2) / **Should** (4.3-4.5)

| # | Effort | Task | Deliverable |
|---|--------|------|-------------|
| 4.1 | 1 day + ongoing | **Test requirement per bug fix** — Add to `CONTRIBUTING.md`. Enforce via PR template (checkbox: "bug fix includes a reproducing test"). CI check: new files in `spec/regression/` or modifications to existing spec files. Run a **CHANGELOG audit**: for each entry in CHANGELOG that says "Fixed ...", verify there is a corresponding test. File issues for untested fixes. | Policy, PR template, regression dir, audit results |
| 4.2 | 1 week | **API misuse test suite** — `GC.free(null)` → no-op, `GC.realloc(null, 0)` → `malloc(0)`, `GC.malloc(0)` → minimum size, `add_root(null)` → ignored, `register_disappearing_link(null, ...)` → ignored, `push_stack` with invalid bounds → ignored, `GC.collect` inside finalizer → reentrancy safety. | API hardening test |
| 4.3 | 1-2 weeks | **Signal policy alignment** — Document: GC is **not** async-signal-safe ([POLICY.md](POLICY.md)). Tests must not claim handler-safe `GC.malloc`/`GC.collect`. Crystal `Signal.trap` deferred alloc is OK (event-loop mutator). True POSIX-handler GC remains forbidden (no “should be safe” suite). | Policy + comment/test honesty |
| 4.4 | 1 week | **Fork test suite** — Heap state before/after fork. `GC.init` (reinit) after fork. Child alloc + collect. Parent alloc + collect (unaffected). Multi-thread fork (Crystal forbids, but test graceful error). | Fork test suite |
| 4.5 | 1-2 weeks | **Finalizer complex scenarios** — Finalizer chain, finalizer calling `GC.collect`, resurrection via add_root, finalizer + disappearing links interaction, finalizer under heavy allocation pressure, many disappearing links. | Finalizer edge case suite |

**What could go wrong:**
- **CHANGELOG audit reveals many untested fixes (4.1):** Could be demoralising. Mitigation: treat this as a backlog — file issues, don't block Phase 4. Prioritise recent regressions (v0.12+) over historical ones.
- **Signal tests confused with async safety (4.3):** Crystal `Signal.trap` is deferred; claiming “async-signal-safe GC.malloc” contradicts POLICY. Mitigation: align comments/CHANGELOG/TEST_PLAN with POLICY; keep trap tests as event-loop coverage only.
- **Fork tests unreliable in CI (4.4):** Fork in CI containers can behave differently. Mitigation: run fork tests on a dedicated CI job with `process_spec/` (already uses `-Dgc_none`).

**Definition of Done:**
- [x] `CONTRIBUTING.md` has "bug fix must include test" policy
- [x] PR template has the reproducing test checkbox
- [x] `spec/regression/` directory exists with **4** entries
- [ ] CHANGELOG audit is complete — issues filed for every untested fix
- [x] API misuse tests pass: null free, null realloc, zero malloc, etc.
- [x] Signal policy aligned with [POLICY.md](POLICY.md) — no “async-signal-safe GC” claims; Crystal `Signal.trap` tests labeled as deferred event-loop path
- [x] Fork tests pass on Linux + macOS

**Success signal:** Every CHANGELOG "Fixed" entry has a companion test. API misuse tests pass without crash. Docs forbid GC from true async signal handlers.

---

### Phase 5: Performance & Regression (ongoing)

**Goal:** Catch performance surprises automatically. Establish benchmark discipline.

**Why it matters:** Without variance-aware benchmarks, perf regression alerts are noise machines. Without microbenchmarks, you can't pinpoint what regressed. A GC's performance is as important as its correctness — a correct but slow GC serves nobody.

**Priority: Must**

| # | Effort | Task | Deliverable |
|---|--------|------|-------------|
| 5.1 | 2-3 weeks | **Perf regression alerting** — GitHub Action: `bench/perf_smoke.sh` on every PR. Gate: gcry /json ≥ 70% of Boehm **same-host**. Variance protocol: N wrk runs, discard min/max, median + noise ratio. Per-run JSON in `bench/log/` (artifact). No committed absolute-RPS baseline (CI ≠ macOS ≠ WSL). | CI alerting |
| 5.2 | 2-3 weeks | **Microbenchmark suite** — `bench/micro/`: alloc latency (p50/p99 per size class), free latency, collect latency (p50/p99/max), TLAB refill cost, parallel mark steal cost, barrier arming cost, STW suspend/resume latency, GC safepoint check overhead. CI regression gate with 5% threshold. | Microbenchmarks |
| 5.3 | 1 week | **Pause time budget test** — Assertions: major p99/max scaled to live set, incremental `collect_a_little` slice (STW-aware budget), minor ≤ major. *Do not* run under `GCRY_DEBUG_INVARIANTS=1` with `-Dgc_none` (checker allocates → stack overflow). | Pause budget suite |
| 5.4 | 1 week | **RSS leak detection** — Intra-run gate: late-half median RSS vs early-half &lt;10% growth. RSS/heap ratio logged only. `bench/trend.json` gitignored artifact. | RSS leak gate |

**Benchmark variance protocol:**

```
For each workload (same host, same job):
  1. Run N iterations of wrk (default 5; CI often 3)
  2. Discard min and max
  3. Report median of remaining
  4. Report IQR / median as noise ratio (informational)
  5. Gate: gcry median / Boehm median >= MIN_PCT (default 70%)
```

**What could go wrong:**
- **wrk noise ratio > 0.15 (5.1):** The 0.15 threshold may be too tight for noisy CI environments. Mitigation: start with 0.25, tighten over time. Document the chosen threshold and why. If still noisy, increase iterations from 5 to 10.
- **Microbenchmark suite takes too long (5.2):** Measuring p99 latency per size class requires many iterations. Mitigation: measure only representative size classes (16, 64, 256, 1024, 4096) not all 60+. Target: microbenchmarks finish in < 5 min.
- **Cross-host absolute baselines are meaningless (5.1/5.4):** CI ≠ macOS ≠ WSL for RPS and RSS. Mitigation: thr gate is same-run % of Boehm; RSS gate is intra-run late-vs-early growth only. No committed `baseline.json`.

**Definition of Done:**
- [x] `bench/perf_smoke.sh` has variance protocol implemented (5 runs, min/max discard, median, noise ratio)
- [ ] PR comment posts before/after perf numbers automatically
- [x] `bench/micro/` exists with at least 6 benchmarks covering alloc, free, collect, TLAB, STW, lock overhead
- [x] Microbenchmarks run in CI with < 5 min overhead (current: ~6s)
- [x] Pause budget assertions pass in CI (`bench/pause_budget.cr`)
- [x] RSS leak gate is intra-run growth only (`bench/rss_leak.cr`); `bench/trend.json` is local/CI artifact (gitignored)

**Success signal:** Microbenchmark suite runs in CI, perf regression alerts fire only on real regressions (no false positives in 1 month), RSS leak trend visible.

---

### Phase 6: Platform & Integration

**Goal:** Equal confidence across every platform.

**Why it matters:** A GC that works only on Linux is not a GC — it's a Linux experiment.

**Priority: Should** (6.1) / **Nice** (6.2 is blocked upstream)

| # | Effort | Task | Deliverable |
|---|--------|------|-------------|
| 6.1 | 2-3 weeks | **Darwin test parity** — Soft-dirty stub returns false. Mprotect stub returns false. Stack bounds via `pthread_get_stackaddr_np` tested. Mach `thread_suspend`/resume STW tested. RSS reclaim (`MADV_FREE_REUSABLE`) tested. All existing spec/process_spec green on macOS CI. | Darwin full suite |
| 6.2 | — | **Windows plan** — **BLOCKED in gcry:** Crystal has basic `-Dgc_none` via Win32 `HeapAlloc` ([crystal#15173](https://github.com/crystal-lang/crystal/pull/15173)), but gcry has no Windows platform layer (`VirtualAlloc`, Win32 STW, barrier stubs, CI). See [INTEGRATION.md](INTEGRATION.md#windows-blocked). When ported: VirtualAlloc/VirtualFree test, Win32 thread suspend test, CI runner. | Blocked (gcry port) |
| 6.3 | 2-3 weeks | **Crystal compiler integration test** — Run Crystal stdlib GC-related specs under `-Dgc_none` + gcry. Verify `GC.malloc`/`GC.free`/`GC.collect` contract. Verify `@crystal_type_id` correctness in compiled output (sample: print type_id at runtime). Test `crystal tool` commands (hierarchy, docs) under gcry. | Compiler integration |
| 6.4 | 1-2 weeks | **Real-world app test** — `bench/kemal/` full HTTP suite: every endpoint, concurrent requests (wrk -c 100), 1-hour long-running, response correctness (status + body). Fat app scenario (acikturkiye-like: many types, large object graph). | E2E app test |

**What could go wrong:**
- **macOS CI is unreliable (6.1):** GitHub macOS runners are slower and less available than Linux. Mitigation: run only `spec/` on macOS CI, keep `process_spec/` for Linux-only. Add macOS process_spec as a separate nightly job.
- **Crystal stdlib specs fail under gcry (6.3):** Not all stdlib specs may be compatible with `-Dgc_none`. Mitigation: start with a subset — test only the GC-related specs (`spec/std/gc_spec.cr`, `spec/std/hash_spec.cr`). Do not aim for 100% stdlib pass rate.
- **Real-world app test is flaky (6.4):** Kemal + wrk in CI may time out. Mitigation: use a shorter duration (10 min), not 1 hour. Keep 1-hour runs for nightly/weekly cron.

**Definition of Done:**
- [x] All `spec/` tests pass on macOS CI *(CI `test-macos`)*
- [x] All `process_spec/` tests pass on Linux CI *(and Darwin CI)*
- [x] Darwin platform stubs are tested (soft-dirty returns false, mprotect returns false) — `spec/platform_darwin_spec.cr`
- [x] Mach STW test exists and passes on macOS — `process_spec/process_gc_spec.cr` (Darwin section)
- [x] Windows blocker is tracked and linked — [INTEGRATION.md](INTEGRATION.md#windows-blocked), crystal#15173 + gcry port gap
- [x] Crystal stdlib GC spec subset runs green under `-Dgc_none` — `bench/compiler_gc_contract.cr` (mirrors `spec/std/gc_spec.cr` + type_id/malloc contract)
- [x] `bench/kemal/` E2E — endpoint correctness + concurrent wrk (`bench/kemal_e2e.sh`); CI 60s; full 10-min via `KEMAL_E2E_DURATION=600 make kemal-e2e`

**Success signal:** macOS CI exercises Darwin stubs + Mach STW. Compiler GC contract + crystal tools pass. Kemal E2E green. Windows dependency is tracked (gcry port + crystal#15173).

---

### Phase 7: Tooling & Observability (ongoing)

**Goal:** See inside the GC and measure test quality.

**Why it matters:** A GC is a black box. Trace logs and heap dumps turn it into a glass box — invaluable for debugging and regression analysis.

**Priority: Nice**

| # | Effort | Task | Deliverable |
|---|--------|------|-------------|
| 7.1 | 1-2 weeks | **GC trace log** — `GCRY_TRACE=1` logs every GC event as JSON lines: alloc (ptr, size, class), collect (start, mark_end, sweep_end), finalizer (registered, run), barrier (arm, dirty_page, scan). Test: suite runs under trace, output is valid NDJSON, parseable. | Trace log |
| 7.2 | 2-3 weeks | **GC heap dump** — `Gcry.dump_heap(io)`: all live objects with address, size, type_id, mark bit, root set. Leak detection: compare dumps between two collects to find leaked objects. Test: dump matches independent traversal. | Heap dump |
| 7.3 | TBD | **Mutation testing** — First evaluate existing Crystal mutation tools (`crystal-mutate` or similar). If none exist, start with targeted source-level mutations on critical paths (swap `==`/`!=`, flip booleans, remove null checks in heap.cr, collect_stw.cr). Mutation score target: 80%+ (killed mutations / total mutations). Run weekly. | Mutation score |

**What could go wrong:**
- **GCRY_TRACE generates too much data (7.1):** JSON-per-alloc can produce GBs of logs under stress. Mitigation: sample rate (log 1 in 1000 allocs), or only log events above a threshold (e.g., collect events always, alloc events sampled).
- **Heap dump performance (7.2):** Traversing the full live set may pause the program for seconds on large heaps. Mitigation: document as a debug-only tool, not for production. Add a size warning: "dumping 1GB+ heap may take > 10s".
- **No Crystal mutation tool exists (7.3):** Starting from scratch is a multi-month project. Mitigation: don't build a general tool. Write 20-30 hand-crafted mutations targeting gcry's critical paths (heap freelist, mark bitmap, sweep logic). Track kill rate manually.

**Definition of Done:**
- [x] `GCRY_TRACE=1` produces valid NDJSON output — `Gcry::Trace`, `bench/trace_smoke.cr`
- [x] Test suite runs clean under `GCRY_TRACE=1` — reentrancy-guarded; alloc sampled (`GCRY_TRACE_ALLOC_SAMPLE`)
- [x] `Gcry.dump_heap(io)` exists and output is parseable — `src/gcry/heap_dump.cr`, `spec/trace_dump_spec.cr`
- [x] Heap dump matches an independent traversal (test assertion)
- [x] Mutation testing feasibility is documented: no Crystal tool; custom `bench/mutations/` — [MUTATION.md](MUTATION.md)
- [x] At least 10 targeted mutations exist, kill rate is tracked — `./bench/mutations/run.sh` (**10/10** killed)

**Success signal:** Trace log + heap dump available for debugging. Mutation harness scores ≥80% on the hand-crafted set.

---

### Top 3 Short-Term Priorities

1. **Fix Parallel EC >2 under process STW** — `stw_mt_property_test --workers=4` lost-root / double-free.
2. **Fat-app (acikturkiye) Linux re-cut** — replace ~2.65× *est.* with measured numbers.
3. **Compiler stack maps** — product lever for fat-app RSS (not more suite polish).

---

### Quick-Reference: All Phases at a Glance

| Phase | Priority | Effort | What you get |
|-------|----------|--------|-------------|
| 1. Foundation | Must | 4-6 weeks | Visibility into untested code, Valgrind-clean CI, deterministic fuzz replay |
| 2. Property-Based Testing | Must / Should | 6-11 weeks | Random exploration catches what hand-written tests miss |
| 3. Stress & Soak | Should | 5-7 weeks + infra | 24h stability, OOM safety, thread death tolerance |
| 4. Regression & Edge Cases | Must / Should | 4-7 weeks | Regression-proof bug fixes, API hardening, signal/fork safety |
| 5. Performance & Regression | Must | 6-10 weeks | Variance-aware perf alerts, microbenchmarks, pause budgets |
| 6. Platform & Integration | Should / Nice | 5-8 weeks | Darwin parity, compiler integration, E2E app tests |
| 7. Tooling & Observability | Nice | 4-7 weeks | Glass-box debugging with trace logs and heap dumps |

**Total estimated effort (all phases):** ~35-55 weeks depending on parallelism and infrastructure setup.

---

### CHANGELOG Regression Audit

Audit completed during Phase 4.1. Key "Fixed" entries now have regression tests:

- **v0.14.0 — `live_objects` counter drift on dormant chunks** → `spec/regression/1_live_objects_dormant.cr` ✅
- **v0.12.0 — Hash layout entries_size SEGV** → `spec/regression/2_hash_layout_entries_size.cr` ✅
- **v0.12.0 — Layout scan_cap alloc_size mismatch** → `spec/regression/3_scan_cap_alloc_size_mismatch.cr` ✅
- **v0.8.0 — Fork reinit after fork** → `bench/fork_reinit.cr` ✅
- **v0.7.0 — Signal stack false root** → `spec/regression/4_signal_stack_false_root.cr` ✅

Remaining older fixes (v0.9–v0.6) are exercised by the general spec suite (stress, collect, sweep, etc.) but lack dedicated regression tests. Track in GitHub issues for future backlog.