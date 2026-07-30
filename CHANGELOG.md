# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

### Fixed

- **No live TLAB steal:** `steal_from_other_tlabs` could null another thread's freelist head while that thread was in lock-free `tlab_alloc_small` (TOCTOU dual-alloc). Removed cross-TLAB steal; idle freelists return via STW `flush_all_tlabs`. `@tlab_steals` stays 0 (metric reserved for a future CAS steal).
- **FREE-claim × minor:** stack/thread FREE-claim cleared `FREE` before the minor/old filter, so an old freelist node became USED-unmarked and scrub dropped it. Skip claim entirely for old nodes during minor (minor never munmaps old chunks); nursery nodes still claim+mark.
- **Parallel worker STW stack scan:** `scan_other_thread_stacks` used `max(stack_top, sp)` for running fibers; stale `stack_top` above hardware SP skipped live frames, so Parallel+TLAB in-flight mallocs were swept (pin saw FREE). Prefer suspend SP (+ x86_64 red zone), mark saved GP registers from the suspend `ucontext`, and with TLAB scan the full fiber stack (SP/greg alone still flaked under Parallel>2). CI: `stw_mt_property_test --tlab --nursery` mixes minors.
- **TLAB FREE-claim chain mark:** stack/thread FREE-claim only marked the current freelist `user`; TLAB batch tails reachable via `next_free` stayed unmarked FREE, so empty-chunk release munmapped them and `tlab_alloc_small` SEGVd in `BlockHeader.free?` (Kemal `GCRY_TLAB=1` @ EC1). Claim now marks the `next_free` chain (keep FREE on tails); abandon TLAB heads that fail `find_block`.
- **Parallel mutator heap-index races (partial):** under `EC_PARALLELISM>1`, `chunk_containing` / last-chunk cache raced `index_insert` (false `owns_user_pointer?` / corruption). Added `@index_lock`; `with_alloc_lock` always locks (was a no-op when TLAB off); `ensure_tlabs` boots under `@alloc_lock`. Process-STW other-thread fiber stacks always full-scan. Kemal `EC>1` HTTP still fails — see FINDINGS.
- **TLAB per-slot freelist locks:** Parallel dual-alloc on lock-free TLAB heads (`ec_alloc_stress` double-free / `not a gcry allocation`). Per-slot `Crystal::SpinLock` (StaticArray — no GC malloc under `@alloc_lock` at boot). STW `flush_all_tlabs` must not take slot locks (suspended mutator may hold them). Refill always re-claims under the slot lock. Kemal `EC>1` still open.
- **STW running-fiber scan:** `scan_all_fiber_roots` skipped `fiber.running?`, relying on `thread.@current_fiber`; under Parallel that TLS can be briefly nil so stacks were missed. Under process STW, scan running fiber stacks too; if `current_fiber` is nil, fall back to pthread stack bounds + greg.
- **STW holds `Thread.lock`:** match Crystal `gc/none` — keep the thread-list mutex for the whole stop→start window so Parallel EC cannot `threads.push` + allocate mid-mark/sweep. Necessary, not sufficient; Kemal `EC>1` still flakes (~5/20).
- **realloc suppress-collect + Boehm-like thread stacks:** growing `realloc` sets `@suppress_collect` around the fresh allocate so a mark miss cannot free-then-reuse the pinned buffer mid-copy (String::Builder `/json` double-free). `scan_other_thread_stacks` always scans `current_fiber`'s stack (no `name=="main"` early-out — every Thread main fiber is named `"main"`); also scans the pthread stack when suspend SP lies there. Register `String::Builder` layout (`@buffer` noscan).

## [0.15.0] - 2026-07-29

Correctness release: process-STW × TLAB freelist UAF class fixed and CI-gated;
process-STW MT property harness; acikturkiye Linux re-cut measured; shard RSS
dead-end defaults documented. Supported path remains EC parallelism **1**,
`GCRY_TLAB` **off** (Parallel+TLAB stays experimental).

### Performance

- **Linux Kemal** (same-host median-of-3, `wrk -c 100 -d 30`, scrub on): `/json` **~86%** of Boehm @ **~0.77×** post-GC RSS; `/` **~86%** @ **~0.76×**. Session `bench/log/linux/2026-07-29-151144/` (`bebedae`). Collector defaults unchanged vs 0.14 — thr within host noise of the v0.14 ~89% cut. See [docs/PERF.md](docs/PERF.md) (Linux).
- **acikturkiye Linux re-cut (measured):** `/api/v1/` **~90%** of Boehm thr @ **~2.54×** post-GC RSS (median-of-3, `wrk -c 100 -d 30`, scrub on). Session `bench/log/linux/2026-07-29-112202/` (`9decd01`). Replaces the v0.14.0 ~93% / ~2.65× *estimate*. See [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **Shard RSS A/B (defaults unchanged):** same-host cuts rejected as defaults — Linux HOLED `GCRY_PAGE_DONTNEED`, process-default curated `HTTP::Headers::Key` Hash layout, collect-time mutator `clear_stack`, Linux 1 MiB large-cache floor. Keep fiber scrub, Linux **4 MiB** large-cache, HOLED **opt-in**; Headers layout stays app-side / `GCRY_AUTO_LAYOUTS`. See [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) “Don’t bother”.

### Fixed

- **Explicit-root list × process STW race:** `add_root`/`delete_root` could run concurrently with `stop_world`, freezing a mutator mid-list splice so `@roots.each` walked a freed/`next`-corrupt `RootNode` (SEGV at `run_collection` during `stw_mt_property_test`). Serialize mutations with `@roots_lock` acquired before STW; collector may mutate without the lock while `@world_stopped`.
- **Parked-fiber scrub on thinly mapped stacks:** Cap wipe to the same 512 B fiber path as `clear_stack` and zero only readable pages via `Roots.clear_range_safe` (defense in depth; Crystal fiber stacks grow on demand).
- **TLAB + Parallel under process STW:** mid-`tlab_alloc_small` STW could leave FREE freelist nodes only reachable from mutator stacks; mark ignored FREE, then empty-chunk release munmapped them (and `unlink_freelist_range` could coerce USED→FREE). Fix: claim FREE stack/thread roots when TLAB+STW (**clear FREE but keep `next_free`** so scrub can walk the chain — `set_used` was severing freelists → OOM), freelist scrub after flush/mark (TLAB-only), flush only FREE nodes, TLAB epoch + detach-before-claim (no dual-alloc after flush), no nested `collect` under `@alloc_lock` (deadlock), unlock-and-collect retry on refill miss, steal stranded TLAB freelists, skip nil `Thread#current_fiber` under Parallel. CI gates `stw_mt_property_test --tlab --workers=2,4`.

### Added

- **Process-GC STW MT property harness:** `bench/stw_mt_property_test.cr` (`-Dgc_none`) runs Parallel allocator workers while the default EC pins roots (ACK handshake) and `GC.collect`s under real STW. Closes the gap left by library-heap `mt_property_test` (`stop_the_world=false`). CI gates `--workers=2,4` and `--tlab --workers=2,4`. (`make stw-mt-property-test`)

### Changed

- **Docs / knobs:** Linux HOLED page release documented as **opt-in** (post-STW; not “STW-heavy”). Large-cache defaults clarified (Linux process **4 MiB**, Darwin **1 MiB**). Darwin `GCRY_DISABLE_PAGE_RELEASE=1` / `GCRY_DISABLE_MADVISE=1` explicitly clear `madvise_free_pages`.

## [0.14.0] - 2026-07-29

Trust and tooling release: industry-style test suite, debug observability, and a
measured Linux Kemal re-cut. Collector throughput unchanged; Kemal post-GC RSS
now measured (not estimated).

### Performance

- **Linux Kemal** (same-host median-of-3, `wrk -c 100 -d 30`, scrub on): `/json` **~89%** of Boehm @ **~0.79×** post-GC RSS; `/` **~89%** @ **~0.78×**. Session `bench/log/linux/2026-07-29-035426/`. See [docs/PERF.md](docs/PERF.md) (Linux). Fat-app (acikturkiye) not re-cut — still ~93% thr / ~2.65× RSS *est.* ([ACIKTURKIYE.md](docs/ACIKTURKIYE.md)).

### Added

- **Debug invariant checker (`GCRY_DEBUG_INVARIANTS=1`):** validates heap invariants at runtime -- `live_objects` counter accuracy, freelist cycle/consistency checks, chunk index integrity, and block overlap detection. Hooks into `malloc`, `free`, and `collect`. Diagnostics use `write(2)` / no managed-heap alloc (not a claim that GC is async-signal-safe). `-Dgcry_invariant_abort` for core dumps. Exposed `Heap#each_chunk`, `#freelist_for`, `#nursery_freelist_for` for the checker. CI runs invariants on every PR. (`spec/invariant_spec.cr`, `make invariants`, CI `Debug invariants` step.)
- **Coverage infrastructure:** `spec/all_specs.cr` entrypoint for kcov (DWARF-based line/branch coverage). `ci/coverage.sh` wrapper runs kcov + `crystal tool unreachable` + `crystal tool macro_code_coverage`. `make coverage` / `coverage-kcov` / `coverage-unreachable` / `coverage-macro` targets. CI `coverage` job builds the spec binary, installs kcov from Debian, and uploads the report. (`ci/coverage.sh`, `Makefile`, `.github/workflows/ci.yml`)
- **Memory safety CI:** `make asan` builds and runs specs with AddressSanitizer (`-Dasan`). `make valgrind-samples` runs samples under Valgrind memcheck (`--leak-check=full`). CI `asan` and `valgrind` jobs on every PR. (`Makefile`, `.github/workflows/ci.yml`)
- **Deterministic replay fuzzing:** `bench/fuzz.cr` rewritten with `--seed=`, `--seconds=`, `--log=`, and `--replay=` flags. Fuzz logs every operation to a replayable log file (opcode + args). Replay mode reads the log and replays the exact sequence of heap operations. Op 9 (spawn + Channel) excluded from logs as non-deterministic Crystal runtime. CI runs fuzz + replay on every PR. (`make fuzz-replay FUZZ_LOG=path`, CI `Fuzz with log + replay` step.)
- **Property-based testing:** `bench/property_test.cr` -- random alloc/free/collect sequences with deep heap invariant verification: `live_objects` counter accuracy (reported == walked count), `heap_size` == sum of chunk `mapped_bytes`, freelist consistency, and per-node `live?` assertion. 100k iterations in ~8s. (`make property-test`, CI `Property test` step.)
- **Layout property test:** `bench/layout_property_test.cr` -- 5 self-contained sub-tests verifying precise scan offset correctness, conservative fallback, leaf layout (scan_cap=0), noscan offset keep-alive semantics, and scan_cap limiting. Runs 10k iterations in ~2.5s. (`make layout-property-test`, CI `Layout property test` step.)
- **MT property test:** `bench/mt_property_test.cr` -- concurrent allocation via fiber workers (2, 4, 8) with periodic collect; verifies no objects lost under concurrent alloc, `live_objects` counter accuracy after TLAB flush, and parallel mark (workers=2) produces the same live set as serial mark (workers=1). 500 iterations × 3 worker counts in ~2.4s. (`make mt-property-test`, CI `MT property test` step.)
- **24-hour soak test:** `bench/soak.cr` -- sustained load with alloc storm (~1000 obj/s), periodic collect (1 Hz), fiber spawn (10 Hz), finalizer load (100 obj/s), WeakRef via disappearing links (10 Hz). Hourly telemetry: heap size, free bytes, live objects, pause p50/p99, RSS. Post-soak RSS check (< 10% growth) and drain verification. Weekly CI cron (Monday 06:00 UTC). (`make soak`, CI `soak` job.)
- **Alloc pattern fuzzing:** `bench/pattern_fuzz.cr` -- 3 allocation distributions (Zipfian power-law, bimodal small+large, stride array-growth) each checked against baseline uniform-random. Verifies pause p99 < 8-10x baseline and RSS growth < 10%. 200 phases × 5000 objects per phase. (`make pattern-fuzz`, CI `Alloc pattern fuzz` step.)
- **Thread storm test:** `bench/thread_storm.cr` -- 3 phases: thread spawn storm (OS threads doing alloc/free/collect in batches), rapid thread create/destroy (250 short-lived threads), Crystal `Signal.trap` deferred alloc (event-loop mutator path; GC is **not** async-signal-safe — see POLICY.md). 1000+ iterations total, 0 errors. (`make thread-storm`, CI `Thread storm` step.)
- **OOM scenarios:** `bench/oom_test.cr` -- 3 phases: bounded heap (low gc_threshold, 500 iterations, no crash), mmap failure (graceful OutOfMemoryError), finalizer under OOM (no crash under pressure). (`make oom-test`, CI `OOM test` step.)
- **Bug-fix test policy:** `CONTRIBUTING.md` with "bug fix must include test" rule, `.github/PULL_REQUEST_TEMPLATE.md` with reproducing test checkbox, and `spec/regression/` directory with 4 regression tests (live_objects dormant chunk, hash_layout entries_size, scan_cap alloc_size mismatch, signal_stack false root). (`spec/regression/`, CI regression jobs.)
- **API misuse test suite:** `spec/api_misuse_spec.cr` -- tests covering `GC.free(null)`, `GC.realloc(null, 0)`, `GC.malloc(0)`, `GC.malloc_atomic(0)`, `Gcry.add_root(null)`, `Gcry.register_disappearing_link(null, ...)`, `collect` inside finalizer (no deadlock), Crystal `Signal.trap` deferred alloc (Linux; not async-signal-safe), `add_root` with large pointer, alternating malloc/free. (`make spec`, CI `spec` step.)
- **Fork reinit test:** `bench/fork_reinit.cr` -- standalone `LibC.fork` + `after_fork_child_reinit` + alloc in child + parent continues allocating after collect. 3 assertions, all pass. (`make fork-test`, CI `Fork reinit test` step.)
- **Finalizer complex scenarios:** `bench/finalizer_complex.cr` -- 7 phases: finalizer chain, finalizer calling `GC.collect`, finalizer adding root (resurrection), finalizer + disappearing links interaction, finalizer under heavy allocation pressure (500 objects), finalizer creating 1000 objects, and many disappearing links (200). 8/8 assertions pass. (`make finalizer-complex`, CI `Finalizer complex scenarios` step.)
- **Perf regression alerting:** `bench/perf_smoke.sh` rewritten with variance protocol -- 5 wrk runs per path, min/max discarded, median reported, noise ratio computed (IQR/median). same-host variance protocol (N wrk runs, min/max discard, median, noise ratio); gate is gcry /json % of Boehm only. Absolute RPS is not compared across hosts. Per-run JSON under `bench/log/` uploaded as CI artifact. (`bench/perf_smoke.sh`, CI `perf smoke` job.)
- **Microbenchmark suite:** `bench/micro/run_all.cr` -- 6-phase suite measuring alloc latency (10 size classes, p50/p99/max), free latency, collect latency (5000 obj, p50/p99/max), TLAB refill cost, STW suspend/resume latency, and GC lock overhead. Runs in < 10s. (`make microbench`, CI `Microbenchmark suite` step.)
- **Pause time budget:** `bench/pause_budget.cr` -- major p99/max budgets scaled to live set, incremental `collect_a_little` slice budget (STW-aware), minor vs major pause ratio. (`make pause-budget`, CI `Pause budget` step.)
- **RSS leak detection:** `bench/rss_leak.cr` -- cyclic alloc/free/collect; gate is intra-run RSS growth only (late-half vs early-half <10%). RSS/heap ratio is informational. Writes gitignored `bench/trend.json`. (`make rss-leak`, CI `RSS leak detection` step.)
- **Darwin platform parity tests (Phase 6.1):** `spec/platform_darwin_spec.cr` asserts soft-dirty/mprotect stubs return unsupported, `pthread_get_stackaddr_np` stack bounds contain the current SP, and host-page-aligned `MADV_FREE_REUSABLE` reclaim works. `process_spec` Darwin section exercises Mach `thread_suspend`/`resume` STW round-trip + SP clamp under `-Dgc_none`. Windows process-GC gap documented in `docs/INTEGRATION.md` (crystal#15173 HeapAlloc stub ≠ gcry port).
- **Compiler GC contract (Phase 6.3):** `bench/compiler_gc_contract.cr` mirrors Crystal `spec/std/gc_spec.cr` (stats/prof_stats/enable) plus malloc/realloc/collect, disable/enable, and runtime `@crystal_type_id` vs `crystal_instance_type_id`. CI also runs `crystal tool hierarchy` / `unreachable` on gcry sources. (`make compiler-gc-contract`)
- **Kemal E2E (Phase 6.4):** `bench/kemal_e2e.sh` hits every endpoint (`/`, `/json`, `/gc-collect`, `/gc-stats`, `/metrics`) before and after concurrent wrk load. CI runs 60s; full 10-min DoD via `KEMAL_E2E_DURATION=600 make kemal-e2e`.
- **GC trace log (Phase 7.1):** `GCRY_TRACE=1` emits NDJSON events (`alloc`/`free` sampled, `collect_start`/`collect_end`, `finalizer`, `barrier_arm`) via `Gcry::Trace`. Reentrancy guard avoids malloc recursion. (`make trace-smoke`, `spec/trace_dump_spec.cr`)
- **Heap dump (Phase 7.2):** `Gcry.dump_heap(io)` / `dump_heap_addresses` / `heap_dump_gone`/`new` for live-object NDJSON and leak diffs. Dump count matches `live_objects`.
- **Mutation harness (Phase 7.3):** `bench/mutations/run.sh` — 10 hand-crafted sed mutants; kill suite scores **10/10**. Feasibility notes in `docs/MUTATION.md`.

### Fixed

- **`Gcry::Trace` under `-Dgc_none`:** do not `require "json"` or write via abstract `IO` — both pulled JSON/OpenSSL into the GC bootstrap and broke process builds. Trace now emits NDJSON with a stack buffer + `LibC.write` to a raw fd.
- **Darwin `release_physical_pages` spec:** do not assert immediate zero-fill after `MADV_FREE_REUSABLE` (kernel may keep contents until reclaim). Assert aligned success + still-mapped only.
- **Nursery HTTP::Headers regression:** moved from `process_spec` to standalone `bench/nursery_headers.cr` — Spec + process GC + nursery was flaky on CI (SEGV during Spec reporting).
- **Process parallel mark:** moved from `process_spec` to `bench/parallel_mark_process.cr` for the same Spec+process-GC flake; CI retries `process_spec` up to 3 times.

- **`live_objects` counter drift on dormant chunks:** the counter was not updated when a fully-free chunk was marked DORMANT during sweep, causing the invariant checker to flag a mismatch (actual=6502, reported=1). *Discovered by the new invariant checker. Covered by `spec/regression/1_live_objects_dormant.cr`.*
- **`after_fork_child_reinit` stability:** `LibC.fork` + reinit + alloc in child, parent continues after collect. Covered by `bench/fork_reinit.cr`.

### Changed

- **Signal policy clarity:** GC is **not** async-signal-safe ([POLICY.md](docs/POLICY.md)). Crystal `Signal.trap` is deferred (event loop); tests/docs no longer claim handler-safe `GC.malloc`.

## [0.13.0] - 2026-07-27

### Changed

- **Darwin `empty_chunk_retain` 8 MB → 512 KB:** Aggressive `MADV_FREE_REUSABLE` reclaim on Darwin. Kemal RSS drops from ~160 MiB to ~18 MiB (1.04× Boehm). ACIKTURKIYE RSS unchanged (~700 MiB); conservative live set remains the dominant driver.
- **`scrub_fibers_enabled` = true (Linux + macOS):** Default-on fiber stack scrubbing to reduce false roots from parked fiber stacks. Linux: Kemal RSS 0.99×→0.95×, acikturkiye RSS 3.00×→2.65×. macOS: ACIKTURKIYE RSS steady at ~700 MiB (conservative live set dominant). Opt-out via `GCRY_DISABLE_SCRUB_FIBERS=1`.
- **Darwin `gc_threshold` 32 MB → 16 MB:** More frequent major collections on Darwin; pause halved (47→25 ms p50) on ACIKTURKIYE.
- **Darwin `small_chunk_bytes` 128 KiB → 256 KiB:** The 128 KiB chunk inflated collection count (~290 majors in 30s) and crushed acikturkiye throughput to ~57% Boehm. 256 KiB recovers throughput to ~78% without meaningful Kemal RSS cost (1.06× vs 0.88×). Set in `gc_override.cr` for Darwin only; library default stays 128 KiB. Escape: `GCRY_CHUNK_BYTES=131072`.

### Added

- **Darwin large-freelist `MADV_FREE_REUSABLE`:** `darwin_release_large_freelist_pages` issues `MADV_FREE_REUSABLE` for every cached large-object chunk after major collection on Darwin, dropping physical pages without unmapping. Linux unchanged (mmap-resident for cache budget).

### Performance

- **macOS v0.13.0** (Apple Silicon M2 Pro, median-of-3, `wrk -c 100 -d 30`, `--release`, 256 KiB chunk default):
  - Kemal: `/` **92.6%** of Boehm; `/json` **83.9%**; post-GC RSS **0.93–1.06×**.
  - ACIKTURKIYE `/api/v1/`: **77.9%** of Boehm, post-GC RSS **15.8×** (~600 MiB). 0 crashes across 3 trials.
  - See [docs/PERF-macos.md](docs/PERF-macos.md), [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).

## [0.12.0] - 2026-07-26

### Added

- **`-Dgcry_side_bitmap` (opt-in):** side `MarkBitmap` mmap path kept for experiments. Default is in-header `MARK` again after Linux A/B showed bitmap default at **82%** `/json` @ **~9.2×** RSS vs header **89%** @ **0.99×** (acikturkiye **50%**→**93%**, **5.6×**→**3.0×**) -- `bench/log/bitmap-ab/FINDINGS.txt`.
- **Bitmap shrinking + adaptive headroom (P1.1):** `MarkBitmap#shrink_to_fit!` reduces the side-mark bitmap mmap when the heap range contracts. Adaptive headroom (25% of recent growth history) prevents immediate re-growth. Combined with tighter `update_heap_bounds_after_unmap`, Kemal RSS drops from ~10× to ~5–7× (when `-Dgcry_side_bitmap`).
- **Darwin `MADV_FREE_REUSABLE` (P1.1, macOS):** `release_physical_pages` switched from the expensive 3-syscall `mach_vm_deallocate`+`allocate`+`protect` to a single `madvise(..., 5)`. `empty_chunk_retain` lowered from 64 MiB to **8 MiB** on Darwin (no cost; `MADV_FREE_REUSABLE` is cheaper than the retain budget).
- **Deferred madvise -- STW pause damping (P1.4):** All `madvise` / page-release syscalls defer to post-STW flush functions (`flush_pending_dormant_chunks`, `flush_pending_page_release_chunks`). DORMANT/HOLED flags set during STW; actual syscalls run after threads resume, eliminating kernel VM lock contention that caused 132–150 ms pause tails.
- **Cross-chunk dormant coalescing (P1.4):** `flush_pending_dormant_chunks` merges contiguous dormant chunks into a single `madvise` region (one syscall per run instead of one per chunk).
- **Per-chunk free-page coalescing (P1.4):** `dontneed_free_pages_in_chunk` pre-computes a live-page mask and issues one `madvise` per contiguous free run instead of one per free page (reduces from up to 64 syscalls/chunk to 1–3).
- **Auto-layouts (P2.1):** `Gcry.register_layouts` whole-program walk + `@unsafe_layouts` blacklist (`Cry` / `Crystal::*` / `LibC::*`; metric `layout_unsafe_skips`). **Opt-in** via `GCRY_AUTO_LAYOUTS=1` (Linux Kemal `/json` ~**−7pp** vs builtins-only -- see `bench/log/thr-abis`). Escape when opted in: `GCRY_DISABLE_AUTO_LAYOUTS=1`.
- **Per-source root reject counters:** New `type_id_stack_rejects` / `type_id_static_rejects` / `type_id_thread_rejects` count where false roots come from (fiber/mutator stacks, BSS/data, TLS). Plus `type_id_root_false_negatives` is now exposed in `/gc-stats`, metrics, and Prometheus -- was tracked but never surfaced. Sum invariant: `stack + static + thread == type_id_root_rejects`.
- **Adaptive nursery threshold:** `@nursery_threshold` adjusts dynamically after each minor based on the moving-average survival rate (last 10 minors). Target survival rate is 50%; when survival rises above it the threshold grows by 25% per minor (reducing collection frequency); when survival drops below 25% the threshold shrinks by 25% (collecting sooner to limit survivor pressure). Clamped to [64 KiB, 8 MiB]. Default-on for process GC (`adaptive_nursery=true`); disable via `GCRY_DISABLE_ADAPTIVE_NURSERY=1`.
- **Large-cache LRU eviction + adaptive retain (P3.3):** `cache_large_chunk` inserts at tail (LRU). `trim_large_cache` evicts from head. Adaptive retain: after each major, hit-rate above 50% doubles retain (capped at 64 MiB); hit-rate below 10% halves it (floor 1 MiB). Default: 1 MiB on Darwin (macOS), 8 MiB on Linux.
- **Bitmap headroom reduced 25% → 12.5%:** `note_bitmap_growth` now uses `avg_range >> 3` instead of `>> 2`, shrinking side-mark bitmap reserve -- less RSS waste on stable heaps.

### Fixed

- **Hash layout walk used `entries_capacity` instead of Crystal `entries_size`:** precise `scan_hash_object` iterated `(1 << indices_size_pow2) / 2` slots. After `realloc`, slots past `@size + @deleted_count` are uninitialized; non-zero garbage `@hash` words caused false marks / mutator UAF under acikturkiye (`GCRY_DISABLE_LAYOUT=1` was the only green bisect). Now walks `@size + @deleted_count`, capped by capacity. Also word-scans `@block` (`Proc?`, 16 bytes) instead of treating it as a single pointer.
- **Layout `scan_cap` required `alloc_size` match:** on size mismatch (raw buffer whose leading `Int32` collided with a registered `type_id`), the old path still applied that type's `scan_cap` and returned -- truncating the mark scan and dropping live pointers (acikturkiye SEGV with layouts on; green with `GCRY_DISABLE_LAYOUT=1`). Size mismatch now falls through to full conservative scan.

### Changed

- **In-header MARK is default again:** side mark bitmap moved to `-Dgcry_side_bitmap` after Linux HTTP A/B (`bench/log/bitmap-ab`). Headline cut: Kemal `/json` **88.8%** @ **0.99×** RSS; acikturkiye **92.8%** @ **3.0×** -- [docs/PERF.md](docs/PERF.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **Nursery + incremental default-off for process GC:** Linux no longer enables `nursery` / `incremental_auto` by default. Soft-dirty false-negatives under WSL release HTTP (Kemal) caused Hash key UAF / SEGV (`0x0`/`0x4`/`0x11`). Opt in with `GCRY_NURSERY=1` / `GCRY_INCREMENTAL=1` after measuring. Darwin unchanged (already off). Related fixes kept: `realloc` pins old buffers across collect; explicit roots skip `type_id_gate`; old→young always full-walks (soft-dirty is additive only) with one-level buffer chase.
- **`incremental_auto` defaults (P1.3, Linux/Darwin):** *(superseded -- both off by default; see above.)*
- **`GCRY_AUTO_LAYOUTS` opt-in (P2.1):** briefly default-on; reverted after Linux A/B -- builtins-only `/json` **~85%** Boehm vs auto-on **~78%** (`bench/log/thr-abis`). Set `GCRY_AUTO_LAYOUTS=1` to enable.
- **Bench default build:** `bench/run_all.sh` uses pure `--release` again (PERF.md). `--release --debug --error-trace` cost ~15–18pp thr; use `CRYSTAL_FLAGS` / `DEBUG=1` only for SEGV hunting.
- **Nursery default-on for Linux process GC:** *(superseded -- off by default again; see above.)*
- **Darwin blacklist re-enabled:** Previously default-off on Darwin (freelist-abandonment spiral under all-conservative scanning). Layout-precise scans (P2.1) cut false root hits sharply, making the blacklist safe. Escape via `GCRY_DISABLE_BLACKLIST=1`.
- **Darwin aggressive free-page release:** `flush_pending_page_release_chunks` walks ALL kept size-class chunks (not just HOLED) on Darwin. `MADV_FREE_REUSABLE` is page-table-level (no VM lock churn), so the extra walk is cheap per major.
- **Darwin large cache reduced to 1 MiB (adaptive):** Adaptive LRU policy starts at 1 MiB on Darwin (vs 8 MiB on Linux). mach_vm reclaim already punches holes on free, so a fat cache is wasteful; 1 MiB floor avoids mmap churn for the common case.

### Performance

- **Linux** Kemal (WSL2 x86_64, median of 3, pure `--release`, in-header MARK default, session `bench/log/linux/2026-07-26-173602/`): `/` **90.4%** of Boehm; `/json` **88.8%**; post-GC RSS **0.99×**. acikturkiye `/api/v1/`: **92.8%** of Boehm, post-GC RSS **3.00×**. Side-bitmap A/B (`2026-07-26-171942`): `/json` **82.3%** @ **~9.2×**, acik **50.1%** @ **5.58×**. See [docs/PERF.md](docs/PERF.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **macOS** Kemal (Apple Silicon M2 Pro, median of 3, pure `--release`, in-header MARK default, session `bench/log/macos/2026-07-26-181318/`): `/` **85.4%** of Boehm; `/json` **86.5%**; post-GC RSS **1.34–1.36×**. acikturkiye `/api/v1/`: **76.7%** of Boehm, post-GC RSS **22.3×** (RSS improved 2.6× vs prior session; conservative live set remains the dominant driver). See [docs/PERF-macos.md](docs/PERF-macos.md), [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).
- **STW pause tail eliminated:** deferred madvise removes kernel VM lock from the STW window. Max pause drops from 132–150 ms to well under 50 ms on Kemal `/json` c=100.

## [0.11.0] - 2026-07-25

### Added

- **Side mark bitmap:** mark bits live in a separate mmap (one bit per word-aligned heap address), replacing the in-header `MARK` flag. `clear_all_marks` is now a `UInt64` word-by-word zero over the bitmap (full memory bandwidth) instead of a per-block header write. `marked?`/`set_mark`/`clear_mark` are answered from heap-inlined mirror fields (`@mark_bitmap_base` / `@mark_bitmap_base_addr` / `@mark_bitmap_cap_bits`) so the mark hot path no longer dereferences `Gcry.current_mark_bitmap` plus a `MarkBitmap` method. Bitmap relocation publishes the new base pointer **before** unmapping the old mapping; `Heap#destroy` clears the global first then nulls the mirrored fields so stale readers short out.
- **Chunk coalescing on flush:** `flush_pending_empty_chunks` walks the pending list and merges **fully-contiguous** chunks (next.base == current end) into single `munmap` regions (one syscall + one VMA teardown per run instead of one per chunk). Stricter than the naive `<=` check so chunks with a gap (kernel-placed VMA between) are flushed independently.
- **`empty_chunk_retain` bumped to 64 MiB** in the process GC override -- keeps recently-freed chunks as `MADV_DONTNEED` dormant (kernel drops the physical pages, VMA cache survives for fast reuse). 0 MiB regressed ~70% via mmap/madvise cycling; 32 MiB regressed ~50% (reclaim thrashing); 64 MiB is the sweet spot.

### Changed

- **HDR pause histogram:** `@pause_hdr` is a `StaticArray(UInt64, 64)` with bucket indices chosen by `clz` on the elapsed-ns value (1–3 ns, 4–7 ns, …). Exposed via `Gcry.pause_percentile_hdr_ns(p)` and `Gcry.pause_hdr_snapshot` (per Kemal `/gc-stats`).
- **`type_id` gate instrumentation:** `type_id_root_false_negatives` counter for objects rejected by the ambient-root gate that later proved live by other means; bounds the false-negative rate under workloads that mix static-root scanning with type_id gating.
- **Mark-stack prefetch + chunk batching:** the mark loop walks chunk ranges in size-class order with `__builtin_prefetch` on the next chunk header; cache miss count drops on Kemal `/json`.

### Fixed

- **Flush coalescing under-counted `unmapped_bytes` on Linux.** The old `<=` coalescing predicate (`nxt.base <= run_end`) silently skipped chunks whose ranges overlapped or had a small gap (4 KiB page between two separately-mmap'd size-class chunks is common on Linux x86_64). The result was `unmapped_bytes` ~½× `released_chunk_bytes` on `spec/collect_spec.cr:159` ("munmaps fully free size-class chunks on major"), failing CI on Linux x86_64 + aarch64 native + aarch64 cross-compile. Tightened to `nxt.base == run_end` (only fully-contiguous chunks coalesce) so the release count and the unmapped count always match. Verified in `crystallang/crystal:1.21.0` Docker (Linux x86_64): 94/94 unit specs + 13/13 process specs + 5 samples + format + Ameba all pass.

### Performance

- **macOS** Kemal (Apple Silicon, median of 3, scrub off): `/` **~100%** of Boehm (was **~97%**); `/json` **~94%** of Boehm (was **~90%**); post-GC RSS **~10×** (was ~0.97× -- see notes). Latency p50: `/json` **2.3 ms** (was **18 ms**, **−87%**); `/` **1.7 ms** (was **14 ms**, **−95%**). p99 latency within 2× of Boehm on both paths. See [docs/PERF-macos.md](docs/PERF-macos.md).
- **Note on RSS:** the side mark bitmap itself allocates a separate mmap region covering the live heap (1 bit per word-aligned address). For the Kemal workload this adds ~200 MiB of mapped address space on top of the managed heap -- hence the ~10× post-GC RSS. This is the explicit price paid for moving mark bits off the object headers; further reduction requires the bitmap to follow heap-range tightening (see `ensure_bitmap_covers`) or a shared page-cache strategy. The throughput + latency win more than compensates for the higher mapped set on the HTTP workload.
- **Linux** numbers unchanged (this host is Darwin) -- re-record on Linux before citing a new Linux cut. See [docs/PERF.md](docs/PERF.md).

## [0.10.0] - 2026-07-25

### Added

- **macOS process GC (the headline):** `-Dgc_none` + `require "gcry"` is a **real collector on Darwin** (arm64 + x86_64), Crystal **≥ 1.21** -- not stubs.
  - **STW:** Mach `thread_suspend` / `thread_resume` (signal STW under HTTP was ~hang / ~2 req/s)
  - **SP clamp:** `thread_get_state` + `pthread_get_stackaddr_np` stack bounds
  - **Static roots:** dyld main-image `__DATA` / `__DATA_CONST` (`__data` / `__bss` / `__common`; skip `__const`)
  - **Free-page RSS:** host-page `mach_vm_deallocate` + `allocate(FIXED)` (Apple Silicon **16 KiB**; `MADV_DONTNEED` does not drop Darwin RSS)
  - **Defaults:** page blacklist **off** (opt-in `GCRY_BLACKLIST=1`); `large_cache_retain` **0**
  - CI: `macos-latest` native specs + samples
- **`Gcry.register_set(T)`** -- registers `Hash(T, Nil)` for `Set` backing maps.
- **`GCRY_SCAN_CAPS=1`** -- optional whole-program `instance_sizeof` scan caps (fat-app live set often unchanged).

### Changed

- **Layout builtins:** broader curated coverage -- primitive/`String` arrays, `Set`-backing hashes, `Hash`/`Array` + `JSON::Any`, `IO::Memory` (noscan buffer), more `Deque`s. Still not whole-program `GCRY_AUTO_LAYOUTS`.
- **Layout correctness:** `Pointer(T)` noscan uses `!T.has_inner_pointers?` (safe for `Array(JSON::Any)`). Hash keys/values with inner pointers word-scanned.
- **Mark:** size-class mismatch falls back to `scan_cap` when present; precise entries store `instance_sizeof`.
- **Large objects:** mmap aligned to `Platform.host_page_size`; `LARGE_CACHE_LIMIT` hard-caps freelist retain.
- **Blacklist:** page granularity uses `host_page_size`.
- Docs: Linux vs Darwin PERF / ACIKTURKIYE split; README highlights macOS.

### Performance

- **macOS** Kemal (0.10.0 cut, Apple Silicon, median of 3, scrub off): `/` **~97%** of Boehm; `/json` **~90%**; post-GC RSS **~0.96–0.97×** -- see [docs/PERF-macos.md](docs/PERF-macos.md).
- **macOS** acikturkiye `/api/v1/` (median of 3): thr trial-median **~80%**; post-GC RSS **~11.8×** (dense conservative-live; reclaim works) -- see [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).
- **Linux** Kemal / acikturkiye cut numbers unchanged from **0.9.0** (this host is Darwin; re-record on Linux before citing a new Linux cut) -- [docs/PERF.md](docs/PERF.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

## [0.9.0] - 2026-07-24

### Added

- **Process-GC parallel mark (STW-exempt):** with `GCRY_PARALLEL_MARK=N` / `parallel_mark_workers > 1`, helpers are raw `LibC.pthread_create` threads (not Crystal::Thread), so `stop_world` does not suspend them. They steal grey objects under `@mark_lock` (`parallel_mark_stolen`). Fork child abandons the pool via `reset_mark_workers_after_fork`.
- **Library-heap parallel mark:** with `parallel_mark_workers > 1` and `stop_the_world == false`, helper `Thread`s steal grey objects (`parallel_mark_stolen`).
- **Stack scrubbing (no Crystal patch):** `GCRY_CLEAR_STACK=1` zeros a window below SP (skips x86_64 red zone; default every **16** allocs) without calling Fiber/Thread APIs; `GCRY_SCRUB_FIBERS=1` zeros a capped window below each parked fiber's saved SP before mark (not the full unused stack -- that faults pages in and blows RSS). Metrics: `clear_stack_*` / `fiber_scrub_*` (json_stats + Prometheus). Not stack maps; measure before enabling as default.
- Richer `Gcry::Observability.json_stats` (phase timers, mapped/live bytes, TLAB, parallel-mark, barrier) -- Kemal `/gc-stats` uses it.
- Prometheus: TLAB, parallel-mark, phase, layout, SP clamp, barrier, size-class live / released chunk gauges; `gcry_clear_stack_*` / `gcry_fiber_scrub_*`.
- Median-of-3 helpers: `bench/median_kemal_boehm.sh`, `bench/median_acikturkiye_boehm.sh`.

### Changed

- README / HARDENING / POLICY: `GCRY_PARALLEL_MARK` is real for process GC (pthread steals), not counter-only -- and labeled **experimental / measure first** (Kemal `/json` + acikturkiye `/api/v1/` thr **regressed** vs `N=1` in same-host wrk).
- README / HARDENING: document `GCRY_DISABLE_*` escapes, `GCRY_TLAB`, stack-scrub knobs.
- Dogfood docs: [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) + [docs/API.md](docs/API.md) point at Observability routes; acikturkiye `make run-demo-gcry` / README GC section.
- Same-host Kemal (0.9.0 cut, median of 3, scrub off): `/` **~89%** of Boehm; `/json` **~92%**; post-GC RSS **~0.97×** -- see [docs/PERF.md](docs/PERF.md).
- Same-host acikturkiye `/api/v1/` (median of 3, scrub off): thr trial-median **~93%**; post-GC RSS **~2.84×** (was ~3.20× at 0.8.0) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

### Fixed

- **`clear_stack` aarch64 SEGV:** wipe used approximate `pointerof(local)` as SP (mid-frame). With no x86_64 red zone that zeroed the leaf frame (`Invalid memory access @ 0x0` on CI `test (aarch64 native)`). Now reads hardware SP (`Roots.hardware_stack_pointer`) plus a leaf margin.

## [0.8.0] - 2026-07-24

### Added

- **Page-dirty write barriers:** soft-dirty is the official nursery/incremental remembered set; `mprotect`+SEGV is the process-GC fallback (`GCRY_MPROTECT_BARRIER=1` to force, `GCRY_DISABLE_MPROTECT=1` to forbid). See `Gcry::Heap#barrier_backend_name`, `barrier_dirty_rescans`.
- **Sounder incremental termination:** `collect_a_little` re-scans dirty pages before sweep when a barrier backend is armed.
- Pause histogram docs in [docs/PERF.md](docs/PERF.md) (`Gcry.pause_stats` p50/p99).
- Specs: `spec/barrier_spec.cr`.
- **TLAB:** `GCRY_TLAB=1` enables thread-local freelist buffers for parallel ExecutionContext alloc (`tlab_refills` / `tlab_steals`). Flush before STW sweep.
- **Parallel mark knob:** `GCRY_PARALLEL_MARK=N` (API + metrics); true multi-thread mark under Crystal STW awaits STW-exempt workers -- today N>1 still marks serially and increments `parallel_mark_runs`.
- STW SP table: CAS bitmask claim (safe under concurrent suspend; `@@stw_claimed` is `uninitialized Atomic` so GC.init does not trip Crystal.once before Fiber exists).
- Specs: `spec/mt_spec.cr`.
- **Page blacklisting:** process GC records type_id-gate false roots and prefers non-blacklisted freelist pages (`blacklist_hits` / `blacklist_skips`; `GCRY_DISABLE_BLACKLIST=1`).
- **`Gcry.register_layouts`:** auto-registers precise layouts for concrete `Reference` subclasses (skips private / nested generics). Opt-in via `GCRY_AUTO_LAYOUTS=1` or an explicit call -- not process-default (unsound offsets on some stdlib types regress HTTP thr).
- Layout table: **4096** entries, **32** offsets, open-addressing `entry_for` (was 512 + linear scan).
- Specs: `spec/blacklist_spec.cr`.
- **Linux aarch64 STW SP clamp:** `sp_from_ucontext` uses glibc `uc_mcontext.sp` offset (432); install on aarch64 as well as x86_64. CI native `ubuntu-24.04-arm` runs specs + `stw_sp_clamp` + `fork_reinit`.
- **Fork reinit:** `pthread_atfork` registered by default; child resets locks / STW / maps cache (`GCRY_DISABLE_ATFORK=1` restores poison). Smoke: `samples/fork_reinit.cr` under `-Dwithout_mt` (ExecutionContext cannot fork).
- **macOS stubs:** `platform/darwin_stubs.cr` so the shard type-checks on Darwin; process GC still raises at init until Mach STW + dyld roots land.
- **Collector split:** `collect.cr` reopened into `collect_stw` / `collect_scan` / `collect_mark` / `collect_sweep` for contributors.
- **Observability:** `Gcry.metrics`, `Gcry.prometheus_text`, `Gcry::Observability.json_stats`; Kemal `/metrics` + richer `/gc-stats`.
- **Ameba** lint in CI (`make lint`); [docs/API.md](docs/API.md); README gcry-vs-Boehm table; [docs/ANNOUNCE.md](docs/ANNOUNCE.md) draft.

### Fixed

- **`register_layouts`:** skip non-concrete type args (`Array(Int)`, `Runnables(256)`, unbound generics) so fat apps (e.g. acikturkiye) compile even when the method is present but unused.

### Performance

- Same-host Kemal (0.8.0 cut, median of 3): `/` **~91%** of Boehm; `/json` **~89%**; post-GC RSS **~0.93×** -- see [docs/PERF.md](docs/PERF.md).
- Same-host acikturkiye `/api/v1/` (median of 3): thr **~95%**; post-GC RSS **~3.2×** (RSS gate still fail; dense conservative-live) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

## [0.7.0] - 2026-07-24

### Fixed

- **Nursery minors:** do not run finalizers / clear WeakRef links for unmarked **old** objects (`minor_only` leaves them unmarked by design). This crashed process GC under Kemal `GCRY_NURSERY` + concurrent `/json`.
- **Base-pointer-only vs `Array#shift`:** ambient roots stay base-only (RSS); **heap** marks allow interiors so shifted `@buffer` keeps the allocation. Process GC under fiber/`GC.collect` no longer frees live `Array` elements (CI `samples/stress` SIGSEGV).

### Changed

- Large-object freelist reuse is **exact mapped-size** only (no oversized VMA for a smaller need).
- `GCRY_LARGE_CACHE` sets free large bytes retained after post-collect trim (default **8 MiB**).
- Heap / Kemal `/gc-stats`: `large_mapped_bytes`, `small_mapped_bytes`, `small_free_bytes`, `large_cache_retain`, `dormant_chunk_bytes`, `dontneed_bytes`, `empty_chunk_retain`.
- Empty size-class chunk `munmap` deferred **outside STW**; occupancy: `fully_free_chunk_bytes` / `size_class_chunk_count` / `released_chunk_bytes`.
- Size-class occupancy: `size_class_live_bytes` + fill histogram (`chunk_fill_lt25`…`ge75`); `GCRY_CHUNK_BYTES` (default **256 KiB**).
- **Soft-dirty nursery (Phase 11):** Linux `/proc` soft-dirty helpers; chunk-scoped pagemap; dirty-fraction fallback (`GCRY_SOFT_DIRTY_MAX`, default **25%**). `GCRY_NURSERY` stays opt-in (off by default).
- **Phase 12 (shard-only RSS):** process GC **empty-chunk release default-on** (`empty_chunk_retain` default **0** → munmap; `GCRY_EMPTY_CHUNK_RETAIN` / dormant DONTNEED; `GCRY_KEEP_CHUNKS=1` escape). Freelist **range-unlink** on release (no full size-class rebuild). Process majors at **32 MiB**. Mark roots **base-pointer-only** by default (`GCRY_INTERIOR=1` restores interiors on ambient roots; heap marks always allow interiors). `GCRY_TYPE_ID_GATE=1` / `GCRY_PAGE_DONTNEED=1` opt-in. Bench: `GET /gc-collect`.
- **Layout-precise scan (false retention):** `Gcry::Layout` type_id → pointer offsets (StaticArray, boot-safe); size-class gate; noscan buffers; `Gcry.register_hash` entry walk. `GCRY_DISABLE_LAYOUT=1`. Does **not** close acikturkiye RSS (still ~2.8×) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **Root-only `type_id` gate (process default-on):** stack/static candidates must have a plausible Crystal `type_id`; heap-scan marks stay ungated (buffers). `GCRY_DISABLE_TYPE_ID_GATE=1`. acikturkiye: ~15 rejects/major, RSS unchanged (~3×) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **STW SP clamp (process default-on, linux x86_64):** capture RSP in SIG_SUSPEND; clamp other-thread stack scans to used SP (`sp_clamp_hits` / `sp_clamp_fallbacks`; `GCRY_DISABLE_SP_CLAMP=1`). acikturkiye RSS unchanged (~3×) -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

### Performance

- Same-host Kemal (0.7.0 cut, median of 3): `/` **~92%** of Boehm; `/json` **~90%**; post-GC RSS **~0.93×** -- see [docs/PERF.md](docs/PERF.md). (`GCRY_KEEP_CHUNKS=1` ≈ **95%** thr @ ~**3×** RSS.)
- Same-host acikturkiye `/api/v1/` (Phase 12, median of 3): thr **~96%**; **post-GC RSS ~2.55×** -- empty release ~noop; dense conservative-live -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- Soft-dirty on WSL **6.18.33.2**: HTTP nursery still too dirty -- keep opt-in.

## [0.6.0] - 2026-07-23

### Fixed

- Process GC **static roots:** treat kernel-named VMAs (`[anon:…]`, `[stack]`, …) like anonymous -- do not scan them as file-backed (Linux 6.x CI SIGBUS). Stack scans use hole-aware `safe` probing (glibc guard pages inside pthread bounds).
- Process GC **stop-the-world** for Crystal 1.21+ `ExecutionContext` Monitor (SYSMON) thread: suspend other OS threads and scan their stacks. Missing roots caused live objects to be swept under load (`not a size-class payload: 0` / `END_OF_STACK` / Monitor SIGSEGV).
- **Monitor stack bounds:** `GC.current_thread_stack_bottom` now returns this OS thread's pthread stack high address (was a single global `@stack_bottom`, so SYSMON scans were skipped or wrong). Other-thread main fibers use `pthread_getattr_np`.
- Mutator stack scan spills **all** GP registers (not only `setjmp` callee-saved) before scanning; marks every `Fiber` / `Thread` object.
- Process GC `lock_read` / `lock_write` use a real `Crystal::RWLock` so collect does not race fiber `swapcontext`.
- Allocate-black while `@collecting` (mid-collect allocations survive sweep).
- **Static roots:** scan ELF BSS zero-fill only when anonymous RW is **contiguous with** the previous file-backed RW mapping (class vars like `Exception::CallStack::@@skip`), plus main-executable `rw-p` (and small RELRO). Skip all `.so` data and large RELRO (≥64 KiB) -- fat-binary STW was dominated by those word scans. Large-object `munmap` does not invalidate the maps cache; empty-chunk release still does. Object mark clamps `header.size` to the mapped chunk.
- **Fiber roots:** process GC scans suspended stacks **once** via `scan_all_fiber_roots` (no duplicate `push_gc_roots` in `before_collect`).
- **Safe stack scans:** leading PROT_NONE probe, then bulk-scan when ends are readable; hole-aware fallback; fiber scans clamp past the guard.
- STW phase timers (`last_phase_*_ns`) exposed for Kemal `GET /gc-stats`.
- **Finalizers / WeakRef:** process unreachable entries once after mark via index APIs (O(finalizers), no Crystal `Proc` -- a closure mid-collect re-entered `malloc` and crashed). Size-class sweep is inlined (no `each_block` yield).
- **Sweep:** recycle large objects onto a size-bucket freelist instead of `munmap` during STW. Thousands of per-buffer VMAs made Linux `munmap` dominate pauses on HTTP apps; trim cache outside STW when over 64 MiB.
- `free` / `reclaim_small` use chunk size-class (not possibly corrupted `header.size`); `owns_user_pointer?` requires block alignment.
- **`notice_reclaim`:** skip registry scan on `free`/`realloc` unless the object has `FINALIZER` / `DISAPPEARING` header flags (was O(entries) per Array growth -- ~15%+ CPU on acikturkiye).
- **Chunk index:** keep address-sorted `@chunk_index` updated on map/unmap (no dirty full rebuild on every mmap); `owns_user_pointer?` no longer double-looks up via `is_heap_ptr`.

### Changed

- Size-class ceiling **8→32 KiB** (`10240`…`32768`): medium buffers use chunk freelists instead of per-object mmap.
- Skip `malloc` clear while a size-class freelist (or fresh large mmap) is still MAP_ANONYMOUS-zeroed; `SizeClasses.fit` one-pass class lookup.

### Performance

- Same-host Kemal vs **Boehm**: `/` **~105%**, `/json` **~100%** of Boehm req/s; `GCRY_RELEASE_CHUNKS=1` ~**92%** on both -- see [docs/PERF.md](docs/PERF.md).
- Same-host **acikturkiye** `/api/v1/`: gcry **~101%** of Boehm req/s (154 vs 153); RSS still ~3–4× -- see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- Path to parity (same doc): early post-STW ~51% → size-class 16/32 KiB → `notice_reclaim` fast-path → chunk index.

## [0.5.0] - 2026-07-23

### Added

- Pause percentiles: `Gcry.pause_stats` now includes `p50_ns` / `p99_ns` (ring of last 64 pauses).
- Meaningful `GC.prof_stats`: `bytes_before_gc`, `bytes_reclaimed_since_gc`, `reclaimed_bytes_before_gc`, `expl_freed_bytes_since_gc`, `obtained_from_os_bytes`.
- `samples/json_churn.cr` -- Hash/JSON mutation dogfood under process GC.
- CI: aarch64 cross-compile of hello/min/alloc on PR+push; `json_churn` + chunk env knobs on x86_64.

### Changed

- Empty-chunk release stays **opt-in** (`GCRY_RELEASE_CHUNKS=1`); `GCRY_KEEP_CHUNKS=1` forces off.
- Finalizer Array buffers / Proc closures pinned during mark (safe opt-in chunk munmap).
- STW hot path: O(n) static-root×heap exclusion (sorted chunk index merge); `find_object` size-class block-bytes cache; mark stack default 256 KiB.
- Empty finalizer registry skips `on_reclaim` work.

### Performance

- Same-host vs **Boehm**: `/` **~92%**, `/json` **~82%** of Boehm req/s -- see [docs/PERF.md](docs/PERF.md).
- Page-map + per-chunk mark bitmap tried during 0.5 prep; **not shipped** (no `/json` win) -- see [DESIGN.md](DESIGN.md) Phase 8.
- `GCRY_RELEASE_CHUNKS=1` still ~**49%** of Boehm `/json` -- remains opt-in.

## [0.4.0] - 2026-07-23

### Added

- Empty size-class chunks can be `munmap`'d after major (`release_empty_chunks`; enable with `GCRY_RELEASE_CHUNKS=1`).
- `GC.stats.unmapped_bytes` / heap `unmapped_bytes` count returned mappings.
- Fork skeleton: `GC.note_fork_child` poison -- post-fork `malloc`/`collect` raise (no auto `pthread_atfork` / heap reinit yet).
- `GCRY_INCREMENTAL=1` opt-in for experimental sliced auto-majors.

### Changed

- Process GC default majors are **full STW** again. Incremental auto without write barriers was unsound under pointer-mutating workloads (Kemal `/json` Hash overflow / double-free).
- `stop_world` / `start_world` documented as v0.4 STW stubs (still no-ops at parallelism 1).
- Docs: POLICY / HARDENING updated for chunk release, fork poison, incremental opt-in.

### Performance

- Kemal wrk vs **v0.3.0** (same host): `/` **−2.7%** req/s, **+0.5%** lat.avg; `/json` **−0.6%** req/s, **−0.4%** lat.avg. Throughput-neutral; prioritizes soundness (STW default).

## [0.3.0] - 2026-07-23

### Added

- Pause instrumentation: `last_pause_ns` / `max_pause_ns` / `total_pause_ns` / `pause_count` on `Gcry::Heap`; `Gcry.pause_stats`.
- Env knobs: `GCRY_DISABLE_INCREMENTAL=1`, `GCRY_INCREMENTAL_WORK` (mark units per slice).
- [docs/PERF.md](docs/PERF.md) -- % of Boehm on Kemal wrk (`/` + `/json`).

### Changed

- Process GC auto-major uses **incremental** `collect_a_little` slices (up to 4 per alloc) instead of full STW; opt out with `GCRY_DISABLE_INCREMENTAL=1`.
- Default incremental work budget raised to 1024.
- `maybe_collect` drains in-progress incremental cycles even when under the major threshold.

### Performance

- Kemal wrk vs **0.2.0** on `/` (same host): **+1.2%** req/s, **−33%** lat.avg.
- Bench app: enriched **`GET /json`** (nested JSON alloc stress); formal `/json` baseline **30112** req/s vs Boehm **41748** (~72%).

## [0.2.0] - 2026-07-23

### Changed

- Process GC performance: nursery **off** by default (opt-in via `GCRY_NURSERY`); major threshold **64 MiB**.
- Cached `/proc/self/maps` static-root ranges; skip bulky `libcrypto` / `libssl` / `libpcre` segments.
- O(log n) chunk index for mark pointer lookup.
- README Kemal+wrk numbers: ~75–80k req/s under gcry (vs ~4k with prior defaults).

## [0.1.0] - 2026-07-23

### Added

- **Kemal HTTP bench** (`bench/kemal`) -- realistic `require "gcry"` + `-Dgc_none` app; `make bench-kemal-wrk` runs `wrk -c 100 -d 30`.
- **Phase 7 productization**
  - [docs/POLICY.md](docs/POLICY.md) -- OOM (emergency collect + `OutOfMemoryError`), fork unsupported, not signal-safe.
  - [docs/COMPARISON.md](docs/COMPARISON.md) -- checklist vs bdwgc.
  - Env knobs: `GCRY_NURSERY`, `GCRY_DISABLE_NURSERY` (plus existing major-threshold knobs).
  - `Makefile` for `spec` / `samples` / `bench` / format.
  - `shard.yml` description + repository metadata.
- **Phase 6 performance**
  - Nursery + `minor_collect` (old→young scan without write barriers; survivors promote).
  - Incremental mark via `collect_a_little` / `GC.collect_a_little` (black alloc during cycle).
  - Specs: `spec/phase6_spec.cr`; bench: `bench/churn.cr`.
  - Process GC nursery threshold default: 512 KiB.
- **Phase 5 hardening**
  - Stress specs (`spec/stress_spec.cr`) and process stress sample (`samples/stress.cr`).
  - CI workflow (`.github/workflows/ci.yml`): `crystal spec` + `-Dgc_none` hello/alloc/stress.
  - Env knobs via `LibC.getenv`: `GCRY_THRESHOLD`, `GCRY_DISABLE_AUTO=1`.
  - [docs/HARDENING.md](docs/HARDENING.md) -- false retention, sanitizers, tuning.
- **Phase 4 process GC** -- `gc_override.cr`, static roots, samples.
- **Phase 3** -- fiber roots, finalizers, disappearing links.
- **Phase 2** -- conservative mark–sweep.
- **Phase 1** -- mmap size-class allocator.

### Changed

- CI: create `bin/` before sample builds; Crystal `1.21.0` + `latest` matrix; format check; `samples/min`, env-knob smoke, `bench/churn`.
- README status → Phase 7 complete; development via `make`.
- Crystal 1.21 docs: default `Fiber::ExecutionContext` (parallelism 1); deprecated `-Dpreview_mt`.

### Fixed

- ExecutionContext (Crystal 1.21+ default): refresh stack bottom from `Fiber.current` on collect; `set_stackbottom` matches `gc/none` (`Thread` form when `!without_mt`).
- Static roots: scan file-backed RW segments only; exclude heap chunks per-mapping (not one bounding box).
- Finalizers: `on_reclaim` no longer allocates Crystal Arrays mid-sweep (nested GC / SIGSEGV under Kemal+wrk).
- Avoid Crystal `ENV` during `GC.init` (Fiber/`once` deadlock); use `LibC.getenv`.
- Suppress auto-collect while finalizers run.
- Bootstrap: no `LibC::MAP_FAILED` / runtime size-class Array on malloc path.
- OOM: one emergency collect + retry before raising on heap `mmap` failure.

### Notes

- Phase 0–7 complete (v0.1 productization).
- Default process auto-collect: 4 MiB major; 512 KiB nursery.
- Concurrent mark / compacting / precise GC need compiler cooperation.
- Optional upstream `-Dgc_gcry` backend remains out of scope (shard override is enough).

[Unreleased]: https://github.com/sdogruyol/gcry/compare/v0.15.0...HEAD
[0.15.0]: https://github.com/sdogruyol/gcry/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/sdogruyol/gcry/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/sdogruyol/gcry/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/sdogruyol/gcry/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/sdogruyol/gcry/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/sdogruyol/gcry/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/sdogruyol/gcry/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/sdogruyol/gcry/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/sdogruyol/gcry/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/sdogruyol/gcry/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/sdogruyol/gcry/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sdogruyol/gcry/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sdogruyol/gcry/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sdogruyol/gcry/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sdogruyol/gcry/releases/tag/v0.1.0
