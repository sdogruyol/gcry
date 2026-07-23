# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 3 fiber / weak / finalizer APIs:**
  - `before_collect` + `push_stack` for suspended fiber stack ranges.
  - `add_finalizer` (runs after collect); `register_disappearing_link` (WeakRef-style).
  - `current_thread_stack_bottom`; no-op `lock_*` / `stop_world` / `start_world` (single-thread).
  - Specs in `spec/fiber_spec.cr`.
- **Phase 2 collector:** conservative mark–sweep on `Gcry::Heap`.
  - Explicit roots, optional stack scan, mmap `MarkStack`, threshold auto-collect.
  - Specs in `spec/collect_spec.cr`.
- **Phase 1 allocator:** `mmap` arenas, size classes, large spans, freelists (`spec/heap_spec.cr`).
- Design docs: [DESIGN.md](DESIGN.md), [docs/INTEGRATION.md](docs/INTEGRATION.md), [README.md](README.md).

### Changed

- Integration model: shard reopens `module GC` under `-Dgc_none` ([ysbaddaden/gc](https://github.com/ysbaddaden/gc) pattern); no Crystal patch.

### Notes

- Phase 0–3 complete.
- Next: Phase 4 — reopen `::GC` under `-Dgc_none` and wire Crystal `Fiber` roots.
