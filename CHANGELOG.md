# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 4 process GC:** `src/gcry/gc_override.cr` reopens `::GC` under `-Dgc_none`.
  - LibC bootstrap before `GC.init` (avoids Fiber/`once` deadlock).
  - Fiber roots via `before_collect` → `Fiber#push_gc_roots` → `push_stack`.
  - Linux static roots from `/proc/self/maps` (skips managed heap ranges).
  - Samples: `samples/hello.cr`, `samples/alloc.cr`, `samples/min.cr`.
- **Phase 3:** `before_collect` / `push_stack`, finalizers, disappearing links.
- **Phase 2:** conservative mark–sweep.
- **Phase 1:** mmap size-class allocator.
- Design docs: DESIGN.md, docs/INTEGRATION.md, README.md.

### Fixed

- Avoid `LibC::MAP_FAILED` and runtime Array/`sizeof` constants on the malloc path (they use Crystal `once` and deadlock during `GC.init` before Fiber exists).
- Process `collect` retaining runtime globals via static mapping scans.

### Changed

- Integration: shard + `-Dgc_none` ([ysbaddaden/gc](https://github.com/ysbaddaden/gc) pattern).

### Notes

- Phase 0–4 complete.
- Auto-collect threshold is `UInt64::MAX` in process mode for now (manual `GC.collect` OK).
- Next: Phase 5 hardening (stress, CI, tune static roots / threshold).
