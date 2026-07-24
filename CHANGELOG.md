# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

## [0.8.0] - 2026-07-24

### Added

- **Page-dirty write barriers:** soft-dirty is the official nursery/incremental remembered set; `mprotect`+SEGV is the process-GC fallback (`GCRY_MPROTECT_BARRIER=1` to force, `GCRY_DISABLE_MPROTECT=1` to forbid). See `Gcry::Heap#barrier_backend_name`, `barrier_dirty_rescans`.
- **Sounder incremental termination:** `collect_a_little` re-scans dirty pages before sweep when a barrier backend is armed.
- Pause histogram docs in [docs/PERF.md](docs/PERF.md) (`Gcry.pause_stats` p50/p99).
- Specs: `spec/barrier_spec.cr`.
- **TLAB:** `GCRY_TLAB=1` enables thread-local freelist buffers for parallel ExecutionContext alloc (`tlab_refills` / `tlab_steals`). Flush before STW sweep.
- **Parallel mark knob:** `GCRY_PARALLEL_MARK=N` (API + metrics); true multi-thread mark under Crystal STW awaits STW-exempt workers — today N>1 still marks serially and increments `parallel_mark_runs`.
- STW SP table: CAS bitmask claim (safe under concurrent suspend; `@@stw_claimed` is `uninitialized Atomic` so GC.init does not trip Crystal.once before Fiber exists).
- Specs: `spec/mt_spec.cr`.
- **Page blacklisting:** process GC records type_id-gate false roots and prefers non-blacklisted freelist pages (`blacklist_hits` / `blacklist_skips`; `GCRY_DISABLE_BLACKLIST=1`).
- **`Gcry.register_layouts`:** auto-registers precise layouts for concrete `Reference` subclasses (skips private / nested generics). Opt-in via `GCRY_AUTO_LAYOUTS=1` or an explicit call — not process-default (unsound offsets on some stdlib types regress HTTP thr).
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

- Same-host Kemal (0.8.0 cut, median of 3): `/` **~91%** of Boehm; `/json` **~89%**; post-GC RSS **~0.93×** — see [docs/PERF.md](docs/PERF.md).
- Same-host acikturkiye `/api/v1/` (median of 3): thr **~95%**; post-GC RSS **~3.2×** (RSS gate still fail; dense conservative-live) — see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

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
- **Layout-precise scan (false retention):** `Gcry::Layout` type_id → pointer offsets (StaticArray, boot-safe); size-class gate; noscan buffers; `Gcry.register_hash` entry walk. `GCRY_DISABLE_LAYOUT=1`. Does **not** close acikturkiye RSS (still ~2.8×) — see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **Root-only `type_id` gate (process default-on):** stack/static candidates must have a plausible Crystal `type_id`; heap-scan marks stay ungated (buffers). `GCRY_DISABLE_TYPE_ID_GATE=1`. acikturkiye: ~15 rejects/major, RSS unchanged (~3×) — see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- **STW SP clamp (process default-on, linux x86_64):** capture RSP in SIG_SUSPEND; clamp other-thread stack scans to used SP (`sp_clamp_hits` / `sp_clamp_fallbacks`; `GCRY_DISABLE_SP_CLAMP=1`). acikturkiye RSS unchanged (~3×) — see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

### Performance

- Same-host Kemal (0.7.0 cut, median of 3): `/` **~92%** of Boehm; `/json` **~90%**; post-GC RSS **~0.93×** — see [docs/PERF.md](docs/PERF.md). (`GCRY_KEEP_CHUNKS=1` ≈ **95%** thr @ ~**3×** RSS.)
- Same-host acikturkiye `/api/v1/` (Phase 12, median of 3): thr **~96%**; **post-GC RSS ~2.55×** — empty release ~noop; dense conservative-live — see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- Soft-dirty on WSL **6.18.33.2**: HTTP nursery still too dirty — keep opt-in.

## [0.6.0] - 2026-07-23

### Fixed

- Process GC **static roots:** treat kernel-named VMAs (`[anon:…]`, `[stack]`, …) like anonymous — do not scan them as file-backed (Linux 6.x CI SIGBUS). Stack scans use hole-aware `safe` probing (glibc guard pages inside pthread bounds).
- Process GC **stop-the-world** for Crystal 1.21+ `ExecutionContext` Monitor (SYSMON) thread: suspend other OS threads and scan their stacks. Missing roots caused live objects to be swept under load (`not a size-class payload: 0` / `END_OF_STACK` / Monitor SIGSEGV).
- **Monitor stack bounds:** `GC.current_thread_stack_bottom` now returns this OS thread's pthread stack high address (was a single global `@stack_bottom`, so SYSMON scans were skipped or wrong). Other-thread main fibers use `pthread_getattr_np`.
- Mutator stack scan spills **all** GP registers (not only `setjmp` callee-saved) before scanning; marks every `Fiber` / `Thread` object.
- Process GC `lock_read` / `lock_write` use a real `Crystal::RWLock` so collect does not race fiber `swapcontext`.
- Allocate-black while `@collecting` (mid-collect allocations survive sweep).
- **Static roots:** scan ELF BSS zero-fill only when anonymous RW is **contiguous with** the previous file-backed RW mapping (class vars like `Exception::CallStack::@@skip`), plus main-executable `rw-p` (and small RELRO). Skip all `.so` data and large RELRO (≥64 KiB) — fat-binary STW was dominated by those word scans. Large-object `munmap` does not invalidate the maps cache; empty-chunk release still does. Object mark clamps `header.size` to the mapped chunk.
- **Fiber roots:** process GC scans suspended stacks **once** via `scan_all_fiber_roots` (no duplicate `push_gc_roots` in `before_collect`).
- **Safe stack scans:** leading PROT_NONE probe, then bulk-scan when ends are readable; hole-aware fallback; fiber scans clamp past the guard.
- STW phase timers (`last_phase_*_ns`) exposed for Kemal `GET /gc-stats`.
- **Finalizers / WeakRef:** process unreachable entries once after mark via index APIs (O(finalizers), no Crystal `Proc` — a closure mid-collect re-entered `malloc` and crashed). Size-class sweep is inlined (no `each_block` yield).
- **Sweep:** recycle large objects onto a size-bucket freelist instead of `munmap` during STW. Thousands of per-buffer VMAs made Linux `munmap` dominate pauses on HTTP apps; trim cache outside STW when over 64 MiB.
- `free` / `reclaim_small` use chunk size-class (not possibly corrupted `header.size`); `owns_user_pointer?` requires block alignment.
- **`notice_reclaim`:** skip registry scan on `free`/`realloc` unless the object has `FINALIZER` / `DISAPPEARING` header flags (was O(entries) per Array growth — ~15%+ CPU on acikturkiye).
- **Chunk index:** keep address-sorted `@chunk_index` updated on map/unmap (no dirty full rebuild on every mmap); `owns_user_pointer?` no longer double-looks up via `is_heap_ptr`.

### Changed

- Size-class ceiling **8→32 KiB** (`10240`…`32768`): medium buffers use chunk freelists instead of per-object mmap.
- Skip `malloc` clear while a size-class freelist (or fresh large mmap) is still MAP_ANONYMOUS-zeroed; `SizeClasses.fit` one-pass class lookup.

### Performance

- Same-host Kemal vs **Boehm**: `/` **~105%**, `/json` **~100%** of Boehm req/s; `GCRY_RELEASE_CHUNKS=1` ~**92%** on both — see [docs/PERF.md](docs/PERF.md).
- Same-host **acikturkiye** `/api/v1/`: gcry **~101%** of Boehm req/s (154 vs 153); RSS still ~3–4× — see [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).
- Path to parity (same doc): early post-STW ~51% → size-class 16/32 KiB → `notice_reclaim` fast-path → chunk index.

## [0.5.0] - 2026-07-23

### Added

- Pause percentiles: `Gcry.pause_stats` now includes `p50_ns` / `p99_ns` (ring of last 64 pauses).
- Meaningful `GC.prof_stats`: `bytes_before_gc`, `bytes_reclaimed_since_gc`, `reclaimed_bytes_before_gc`, `expl_freed_bytes_since_gc`, `obtained_from_os_bytes`.
- `samples/json_churn.cr` — Hash/JSON mutation dogfood under process GC.
- CI: aarch64 cross-compile of hello/min/alloc on PR+push; `json_churn` + chunk env knobs on x86_64.

### Changed

- Empty-chunk release stays **opt-in** (`GCRY_RELEASE_CHUNKS=1`); `GCRY_KEEP_CHUNKS=1` forces off.
- Finalizer Array buffers / Proc closures pinned during mark (safe opt-in chunk munmap).
- STW hot path: O(n) static-root×heap exclusion (sorted chunk index merge); `find_object` size-class block-bytes cache; mark stack default 256 KiB.
- Empty finalizer registry skips `on_reclaim` work.

### Performance

- Same-host vs **Boehm**: `/` **~92%**, `/json` **~82%** of Boehm req/s — see [docs/PERF.md](docs/PERF.md).
- Page-map + per-chunk mark bitmap tried during 0.5 prep; **not shipped** (no `/json` win) — see [DESIGN.md](DESIGN.md) Phase 8.
- `GCRY_RELEASE_CHUNKS=1` still ~**49%** of Boehm `/json` — remains opt-in.

## [0.4.0] - 2026-07-23

### Added

- Empty size-class chunks can be `munmap`'d after major (`release_empty_chunks`; enable with `GCRY_RELEASE_CHUNKS=1`).
- `GC.stats.unmapped_bytes` / heap `unmapped_bytes` count returned mappings.
- Fork skeleton: `GC.note_fork_child` poison — post-fork `malloc`/`collect` raise (no auto `pthread_atfork` / heap reinit yet).
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
- [docs/PERF.md](docs/PERF.md) — % of Boehm on Kemal wrk (`/` + `/json`).

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

- **Kemal HTTP bench** (`bench/kemal`) — realistic `require "gcry"` + `-Dgc_none` app; `make bench-kemal-wrk` runs `wrk -c 100 -d 30`.
- **Phase 7 productization**
  - [docs/POLICY.md](docs/POLICY.md) — OOM (emergency collect + `OutOfMemoryError`), fork unsupported, not signal-safe.
  - [docs/COMPARISON.md](docs/COMPARISON.md) — checklist vs bdwgc.
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
  - [docs/HARDENING.md](docs/HARDENING.md) — false retention, sanitizers, tuning.
- **Phase 4 process GC** — `gc_override.cr`, static roots, samples.
- **Phase 3** — fiber roots, finalizers, disappearing links.
- **Phase 2** — conservative mark–sweep.
- **Phase 1** — mmap size-class allocator.

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

[Unreleased]: https://github.com/sdogruyol/gcry/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/sdogruyol/gcry/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/sdogruyol/gcry/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/sdogruyol/gcry/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/sdogruyol/gcry/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sdogruyol/gcry/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sdogruyol/gcry/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sdogruyol/gcry/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sdogruyol/gcry/releases/tag/v0.1.0
