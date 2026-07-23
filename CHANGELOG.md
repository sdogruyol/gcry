# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 1 allocator:** `Gcry::Heap` with `mmap` arenas, size classes (16B–8KB), large-object spans, intrusive freelists.
- Block/chunk metadata (`Gcry::BlockHeader`, `Gcry::ChunkHeader`) including flags for free / atomic / large (mark bit reserved).
- Module API: `Gcry.malloc`, `malloc_atomic`, `realloc`, `free`, `is_heap_ptr`, `default_heap`.
- Specs: zeroing, freelist reuse, large alloc, realloc, double-free, foreign pointers, 2000-op fuzz (`spec/heap_spec.cr`).

- Project scaffold (`shard.yml`, MIT license, empty `Gcry` module).
- [DESIGN.md](DESIGN.md) — goals, architecture, phased roadmap, MVP definition.
- [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal 1.21.0 `GC` / fiber research notes (boehm & none backends, root pushing, boot sequence).
- [README.md](README.md) — project overview and shard usage outline.
- [CHANGELOG.md](CHANGELOG.md) — this file.

### Changed

- Integration model: pure shard that reopens `module GC` under `-Dgc_none` (same pattern as [ysbaddaden/gc](https://github.com/ysbaddaden/gc)); no Crystal stdlib/compiler patch required.
- Frozen Phase 0 API contract and decisions in DESIGN.md (flag activation via `-Dgc_none`, `preview_mt` out of MVP).

### Notes

- Phase 0 (research & contract) is complete.
- Phase 1 (allocator, no collection) is complete.
- Next: Phase 2 — conservative mark–sweep.
