# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 5 hardening**
  - Stress specs (`spec/stress_spec.cr`) and process stress sample (`samples/stress.cr`).
  - CI workflow (`.github/workflows/ci.yml`): `crystal spec` + `-Dgc_none` hello/alloc/stress.
  - Env knobs via `LibC.getenv`: `GCRY_THRESHOLD`, `GCRY_DISABLE_AUTO=1`.
  - [docs/HARDENING.md](docs/HARDENING.md) — false retention, sanitizers, tuning.
- **Phase 4 process GC** — `gc_override.cr`, static roots, samples.
- **Phase 3** — fiber roots, finalizers, disappearing links.
- **Phase 2** — conservative mark–sweep.
- **Phase 1** — mmap size-class allocator.

### Fixed

- Avoid Crystal `ENV` during `GC.init` (Fiber/`once` deadlock); use `LibC.getenv`.
- Suppress auto-collect while finalizers run.
- Bootstrap: no `LibC::MAP_FAILED` / runtime size-class Array on malloc path.

### Notes

- Phase 0–5 complete.
- Default process auto-collect threshold: 4 MiB (override with env).
- Next: Phase 6 — incremental / generational performance work.
