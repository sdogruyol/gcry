# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 2 collector:** conservative mark–sweep on `Gcry::Heap`.
  - Explicit roots (`add_root` / `delete_root`), optional stack scan (`set_stackbottom`).
  - mmap-backed `MarkStack`; object graph scan skips `malloc_atomic` payloads.
  - Sweep reclaims small blocks to freelists and unmaps large objects.
  - `collect`, `live?`, `enable` / `disable`, `gc_threshold` auto-collect.
  - Specs in `spec/collect_spec.cr` (roots, tracing, atomic, large, interior ptrs, threshold).
- **Phase 1 allocator:** `Gcry::Heap` with `mmap` arenas, size classes (16B–8KB), large-object spans, intrusive freelists.
- Block/chunk metadata (`Gcry::BlockHeader`, `Gcry::ChunkHeader`) including flags for free / atomic / mark / large.
- Module API: `Gcry.malloc`, `malloc_atomic`, `realloc`, `free`, `is_heap_ptr`, `collect`, `add_root`, `live?`, `default_heap`.
- Specs: allocator + fuzz (`spec/heap_spec.cr`), collection (`spec/collect_spec.cr`).

- Project scaffold (`shard.yml`, MIT license).
- [DESIGN.md](DESIGN.md) — goals, architecture, phased roadmap, MVP definition.
- [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal 1.21.0 `GC` / fiber research notes.
- [README.md](README.md) — project overview and shard usage outline.
- [CHANGELOG.md](CHANGELOG.md) — this file.

### Changed

- Integration model: pure shard that reopens `module GC` under `-Dgc_none` (same pattern as [ysbaddaden/gc](https://github.com/ysbaddaden/gc)); no Crystal stdlib/compiler patch required.
- Frozen Phase 0 API contract and decisions in DESIGN.md.

### Notes

- Phase 0–2 complete (research, allocator, conservative mark–sweep).
- Next: Phase 3 — fiber / thread root registration.
