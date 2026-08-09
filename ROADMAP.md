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
- [x] Fiber stack scrubbing (default-on v0.13.0 → v0.18; **opt-in** on tip)
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
- [x] **Settle `scrub_fibers` on correctness, not perf.** Settled by defaulting
      it **off** on both platforms (`GCRY_SCRUB_FIBERS=1` opts back in): no perf
      axis decides it, and the correctness question is open, so the default goes
      to the side that does not write into memory the collector does not own.
      Still open below: whether a pointer can live only in the wiped region.
      It was carried as
      "loses on every axis measured"; a second session retired that framing.
      The −1.29% throughput is **retracted** — it came back +1.22% with the
      sign flipped, and the knob moves ~0.01% of wall time, so throughput
      cannot resolve it in either direction. Root work is real but larger than
      recorded (−9.1%, not −1.7%) and worth that same ~0.01%. Kemal RSS is
      flat, and the fat-app RSS that put it on default (3.00× → 2.65×) does
      **not** reproduce: n=3 said +46% worse, n=9 said −34.9% better, because
      acik is bistable between a ~44 and a ~72 MiB heap regime. Stratified, it
      is a wash. So no perf axis decides it, and the open question is the one
      it was listed under to begin with: it zeroes memory below a parked
      fiber's *estimated* SP, from another thread.
      `bench/scrub_audit.cr` instruments that, and now **answers it for the two
      shapes gcry ships**: reading foreign SPs from `/proc/self/task/<tid>/
      syscall` removes the signal-path blindness, and separating "SP on a
      *running* fiber" from "SP on a parked one" makes a zero readable. Result:
      the wipe never reached live frames — EC1 200/200 collections, EC4 1170
      sightings, all on fibers excluded as `running?` before any scrub logic
      ran. So the Monitor's stack is protected by the `running?` check, not by
      the EC1 exemption, whose stated rationale ("SYSMON is suspended on its
      fiber") does not describe what happens. The Parallel mid-swap window was
      not observed in 300 collections with the guard off — a bound on its rate,
      not a licence to remove the guard. Still open: whether a pointer can live
      only in the wiped region in a shape not exercised here.
      `docs/SOUND-DEFAULTS.md` § "What `scrub_fibers` costs", § "Auditing the scrub"
- [ ] **Attribute the residual per-rep spread.** Every A/B bottoms out at 1.2–3%
      scatter between reps. Five hypotheses are now eliminated, and the harness's
      own noise floor is measured rather than guessed —
      `bench/log/linux/2026-08-07-050658-root-phase/FINDINGS.md`:
      not the load generator and not the clock (the spread is in the collector's
      own `monotonic_ns` phase medians, no wrk in the loop); not thermal or any
      slow drift (no trend, no lag-1 autocorrelation); **not environmental at
      all** — a null control running the same build against itself gives
      within-rep correlation r ≈ 0 across every phase, so each server process is
      an independent draw; not CCD/L3 placement (the i3-12100F has one L3 shared
      by all 8 CPUs and shows the same spread); not ASLR (`setarch -R` leaves
      scatter unchanged, F ≈ 0.6–1.1). Leading remaining candidate is **physical
      page placement**, which ASLR cannot affect since it randomises virtual
      addresses while L3 indexes physically; testing it needs THP or
      hugepage-backed chunks, not a harness flag.
      **Operative floor until then: ±2–3pp on phase timings, ±1pp on post-GC
      RSS, at 12 reps.** Publish nothing smaller from this host.

- [x] **Cheap root scan at scale — the stack axis.** `lag = 0` scanned every
      parked fiber `guard → bottom`, 8 MiB of reserved address space each, of
      which **0.05% has ever been written** (69 stacks: 552 MiB virtual,
      284 KiB touched). Scanning starts at the stack's low-water mark instead,
      which is not a precision trade — a page with neither the present nor the
      swapped bit in `/proc/self/pagemap` has never been faulted, so it is zero
      and the two ranges see identical words. (`mincore` is the wrong tool: it
      says "resident", so a swapped-out page would be skipped and its pointer
      lost.) Applied to the parked-fiber and pthread-mapping paths.
      **EC4 pause 147 ms → 13 ms, 11.3×**; `make stw-lag-pause` 13.9× → 1.03×;
      RSS unchanged — `bench/log/linux/2026-08-07-110231-root-phase/FINDINGS.md`
- [ ] **Apply the low-water skip to the `lag > 0` default path.** No longer a
      hypothesis: the fat app's large-heap re-cut has `GCRY_SOUND=1` running
      **−25.4% pause / −43.8% root work** against tuned (21 paired reps,
      stratified; `bench/log/linux/2026-08-09-071144-root-phase/`, confirmed at
      9 reps by `…-062117-`). The default is the slower path because the skip is
      gated on `lag == 0`, so tuned still faults in a fixed 256 KiB window per
      parked fiber while sound starts at the low-water mark. Either ungate the
      skip or make `lag = 0` the default — both need a Kemal EC4 control, since
      that shape is where lag 0 still costs (+83%).
- [ ] **Cheap root scan at scale — what is left.** `GCRY_SOUND=1` is still
      +83% pause at EC4 against tuned, and that residual is no longer a constant
      worst case: it tracks how much stack was actually touched (p5 3.4 ms,
      p95 19.1 ms, against tuned's 6.1/7.8). Open: which fibers are deeply used
      and why; and Darwin, which has no pagemap equivalent wired and keeps the
      full scan. **Closed:** the fat-app large-heap re-cut (above — the 14.5×
      was pre-fix and the sign has since reversed).
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
