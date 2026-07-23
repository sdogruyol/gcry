# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

### Fixed

- Process GC **stop-the-world** for Crystal 1.21+ `ExecutionContext` Monitor (SYSMON) thread: suspend other OS threads and scan their stacks. Missing roots caused live objects to be swept under load (`not a size-class payload: 0` / `END_OF_STACK` / Monitor SIGSEGV).
- **Monitor stack bounds:** `GC.current_thread_stack_bottom` now returns this OS thread's pthread stack high address (was a single global `@stack_bottom`, so SYSMON scans were skipped or wrong). Other-thread main fibers use `pthread_getattr_np`.
- Mutator stack scan spills **all** GP registers (not only `setjmp` callee-saved) before scanning; marks every `Fiber` / `Thread` object.
- Process GC `lock_read` / `lock_write` use a real `Crystal::RWLock` so collect does not race fiber `swapcontext`.
- Allocate-black while `@collecting` (mid-collect allocations survive sweep).
- **Static roots:** scan ELF BSS zero-fill only when anonymous RW is **contiguous with** the previous file-backed RW mapping (class vars like `Exception::CallStack::@@skip`), plus RELRO `r--p`. Blanket anon&lt;1MiB incorrectly cached gcry large-object VMAs; scanning them after `munmap` SIGSEGV’d mid-collect (often during ExceptionPage DWARF/`malloc_atomic`). Object mark clamps `header.size` to the mapped chunk. Large-object `munmap` no longer invalidates the maps cache (adjacency never caches those VMAs); empty-chunk release still does. Broader bulky-`.so` skip list for static scans.
- **Safe stack scans:** skip leading PROT_NONE pages with one probe sequence, then bulk-scan; fiber scans that already clamp past the guard use `safe: false` (avoids per-page `write`/`read` STW cost).
- `free` / `reclaim_small` use chunk size-class (not possibly corrupted `header.size`); `owns_user_pointer?` requires block alignment.

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

[Unreleased]: https://github.com/sdogruyol/gcry/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/sdogruyol/gcry/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sdogruyol/gcry/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sdogruyol/gcry/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sdogruyol/gcry/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sdogruyol/gcry/releases/tag/v0.1.0
