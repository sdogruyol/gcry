# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project scaffold (`shard.yml`, MIT license, empty `Gcry` module).
- [DESIGN.md](DESIGN.md) — goals, architecture, phased roadmap, MVP definition.
- [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal 1.21.0 `GC` / fiber research notes (boehm & none backends, root pushing, boot sequence).
- [README.md](README.md) — project overview and shard usage outline.

### Changed

- Integration model: pure shard that reopens `module GC` under `-Dgc_none` (same pattern as [ysbaddaden/gc](https://github.com/ysbaddaden/gc)); no Crystal stdlib/compiler patch required.
- Frozen Phase 0 API contract and decisions in DESIGN.md (flag activation via `-Dgc_none`, `preview_mt` out of MVP).

### Notes

- Phase 0 (research & contract) is complete.
- Collector implementation has not started yet (Phase 1: allocator).
