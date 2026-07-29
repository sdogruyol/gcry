# gcry Roadmap: Aims to become Crystal's default GC

gcry is a conservative mark-sweep garbage collector written in Crystal, shipped as a shard.
This roadmap shows where we are and where we're going — from a shard that replaces Boehm
at build time, aiming toward a future where Crystal ships with its own GC.

## Current (v0.14.0) — "It works, you can use it"

- [x] Conservative mark-sweep, stop-the-world
- [x] Linux + macOS process GC (x86_64 + ARM64)
- [x] Kemal `/json`: **~89%** Boehm throughput (~95% with `GCRY_KEEP_CHUNKS=1`)
- [x] Post-GC RSS: **~0.79×** Linux (measured), **~0.93×** macOS (Kemal)
- [x] Fat app (acikturkiye): ~93% thr, ~2.65× RSS (Linux; *est.*, not re-cut)
- [x] HDR pause histograms, Prometheus metrics, `/gc-stats` observability
- [x] Layout-precise scanning, type_id gate, SP clamp
- [x] macOS Darwin Kemal RSS ~**0.93–1.06×** Boehm (v0.13 cut; MADV_FREE_REUSABLE, 256 KiB chunks)
- [x] Shard-based integration: `require "gcry"` + `-Dgc_none`
- [x] Fiber stack scrubbing (default-on since v0.13.0)
- [x] 16-byte object header, deferred madvise (pause tail eliminated)
- [x] Test suite hardening (invariants, property tests, ASan/Valgrind, soak)
- [x] `GCRY_TRACE` + heap dump observability

---

## Phase 2: Community & Production Readiness

Target: Make gcry easy to adopt, hard to break, and impossible to ignore.

- [ ] **Compiler stack maps** — fat-app RSS 3× → ~1.2× (precise root scanning)
- [ ] **Write barrier** — sound concurrent / incremental GC backend
- [ ] **Windows process GC** — platform stubs + process GC parity
- [ ] **CI for all platforms** — Linux x86_64 + aarch64, macOS arm64, Windows
- [ ] **Benchmark regression alerts** — GitHub Action comparing PR vs baseline perf
- [ ] **Crystal compiler PR: `-Dgc_gcry` flag** — opt-in flag recognized by the compiler
      (no-op alias for `-Dgc_none`; ecosystem signal that gcry is real)
- [ ] **Security / fuzzing** — documented fuzz hours, crash-free stress runs
- [ ] **good-first-issue grooming** — Windows stubs, benchmark workloads, specs
- [ ] **Crystal Discord #gcry channel** — community hub for users and contributors

---

## Phase 3: Performance Parity

Target: Match Boehm on the workloads Crystal users actually run.

- [ ] **Throughput parity with Boehm** on all Kemal-class workloads
- [ ] **Parallel mark** — multi-thread mark without throughput regression
- [ ] **Nursery + incremental on by default** — process GC defaults to generational
- [ ] **Production dogfood** — deploy gcry on a real Crystal service in production
- [ ] **Benchmark leaderboard** — per-release transparent perf tracking in `bench/leaderboard.md`
- [ ] **gcry vs Boehm comparison page** — readable feature matrix (readable source,
      Crystal debug, integrated metrics vs C library)
- [ ] **Release blog posts** — every minor release: what changed, perf numbers,
      one interesting engineering story
- [ ] **"Made with gcry" wall** — list of production users (social proof snowball)

---

## Phase 4: Crystal's Default GC

Target: Crystal compiler defaults to gcry on Linux.

- [ ] **Crystal defaults to gcry on Linux** — no `-Dgc_none` required
- [ ] **Full concurrent collection** — no STW pause at any heap size
- [ ] **Moving / compacting collector** — after precise roots are stable
- [ ] **Windows parity** — full process GC parity across all platforms
- [ ] **Conference talks** — CrystalConf, FOSDEM, local meetups
- [ ] **MacOS default consideration** — platform-by-platform rollout

---

## Non-goals (explicit)

- Being a general C malloc for non-Crystal programs
- Replacing Boehm before correctness and perf parity are earned
- Full concurrent GC without write barriers from the compiler

---

_See [DESIGN.md](./DESIGN.md) for architecture, [docs/COMPARISON.md](./docs/COMPARISON.md)
for the gcry vs Boehm feature matrix, and [docs/PERF.md](./docs/PERF.md) for
current performance numbers._