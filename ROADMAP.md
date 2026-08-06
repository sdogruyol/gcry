# gcry Roadmap: Aims to become Crystal's default GC

gcry is a conservative mark-sweep garbage collector written in Crystal, shipped as a shard.
This roadmap shows where we are and where we're going — from a shard that replaces Boehm
at build time, aiming toward a future where Crystal ships with its own GC.

## Current (v0.18.0) — "Fat-app RSS; shard-only; stack maps dormant"

- [x] Conservative mark-sweep, stop-the-world
- [x] Linux + macOS process GC (x86_64 + ARM64)
- [x] Kemal `/json`: **~87%** Boehm throughput (v0.16 Linux carry; tip smoke ~80–85% host-soft)
- [x] Post-GC RSS: **~0.80×** Linux (Kemal, v0.16 carry), **~0.95–1.01×** macOS (Kemal tip)
- [x] EC1 thr recovery after Parallel-era STW / scrub / counter fallout (v0.16.0)
- [x] Fat app (acikturkiye): Linux ~**90–96%** thr @ ~**1–1.6×** RSS (finalizer + retain=0; i3 ~1.63× / 9950X ~1.0–1.8×; was ~3.43× at v0.17); opt-in `GCRY_TIGHT_GROW` ~**103%** @ ~**0.92×**; Darwin tip ~**90%** @ ~**0.63×** (was ~18×)
- [x] Stack-map machinery ships **dormant** (`GCRY_PRECISE_STACK` default off) — research only
- [x] Parallel **TLAB-off + lazy sweep** supported opt-in (~79% `/json`; not default)
- [x] Process-STW × TLAB freelist UAF class fixed; `stw_mt_property_test` CI-gated
- [x] HDR pause histograms, Prometheus metrics, `/gc-stats` observability
- [x] Layout-precise scanning, type_id gate, SP clamp
- [x] macOS Darwin Kemal RSS ~**0.93–1.01×** Boehm (MADV_FREE_REUSABLE, 256 KiB chunks)
- [x] Shard-based integration: `require "gcry"` + `-Dgc_none` (stock Crystal ≥ 1.21)
- [x] Fiber stack scrubbing (default-on since v0.13.0)
- [x] 16-byte object header, deferred madvise (pause tail eliminated)
- [x] Test suite hardening (invariants, property tests, ASan/Valgrind, soak)
- [x] `GCRY_TRACE` + heap dump observability

---

## Phase 2: Community & Production Readiness

Target: Make gcry easy to adopt, hard to break, and impossible to ignore.

- [ ] **Compiler stack maps** — precise roots (Darwin acik ~18×; Linux tip ~1–1.6× via
      finalizer + retain=0, freelist residual); spike: [docs/STACK_MAPS.md](docs/STACK_MAPS.md)
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

- [ ] **EC1 `/json` ≥95% @ ≤1.0× RSS** — shard-only thr **exhausted**
      (i3 + 9950X hunt MISS; KEEP ~90–95% @ ~3× only). Next lever:
      compiler stack maps — `bench/log/linux/2026-08-02-018-FINDINGS.md`
- [ ] **Throughput parity with Boehm** on all Kemal-class workloads
- [ ] **Turn `scrub_fibers` off by default.** It loses on every axis measured:
      −1.29% throughput (8/9 paired rounds, 3.2σ) and −1.7% of root work on
      Kemal at EC1, while also being a root-completeness heuristic that can
      drop a live pointer. The only member of the class that can go today
      without settling the wider defaults question —
      `bench/log/linux/2026-08-06-140037-sound-profile/FINDINGS.md`
- [ ] **Cheap root scan at scale — the one blocker to sound defaults.**
      `stw_multi_stack_lag = 0` costs 19× pause at Kemal EC4 (7.2 → 141.7 ms)
      and 14.5× on acik at EC1 once its heap passes ~60 MiB (17 → 213 ms);
      `stw_multi_pthread_lag = 0` adds a further +64% at EC4. The other five
      root-completeness heuristics are within ±6% on every workload measured,
      so this pair is the entire cost of `GCRY_SOUND=1`. Make the scan cheap
      enough that lag 0 is affordable and sound-by-default is back on the
      table — `bench/log/linux/2026-08-06-085309-root-phase/FINDINGS.md`.
      Guarded in the meantime by `make stw-lag-pause`, which reproduces 15× of
      it in ~6 s with no server and no EC build; when this lands, that guard's
      ratio collapses toward 1 and it keeps passing.
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
