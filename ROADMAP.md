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
      not a licence to remove the guard. The other half — whether a pointer can
      live only in the wiped region — is now answered by `make scrub-margin`
      (`GCRY_SCRUB_OVERSHOOT` slides the window into live frames, so the sweep
      carries its own positive control): clean through **56 bytes** of
      overshoot, corrupt at **60**. That boundary is `swapcontext`'s six
      callee-saved registers plus the return address, so **the margin is zero** —
      the wipe ends exactly where live data begins, and correctness rests
      entirely on `@context.stack_top` being exact on every platform and through
      any change to how Crystal spills. No defect at the shipping window; no
      tolerance either. **The mid-swap suspend is now closed too**, and the
      reason no harness hit it is structural rather than luck: on all five
      Crystal context-switch backends `stack_top` is written (behind a `dmb ish`
      on aarch64) *before* the running flag is cleared, and a resumed fiber is
      marked running *before* the SP moves onto its stack, so while the genuine
      window is open `stack_top == sp` and the wipe stays strictly below it.
      `Fiber#run` delists a dying fiber before its stack reaches the pool, which
      closes the other direction. That is an argument from source (Crystal
      `c361ac6e7`), so `make scrub-midswap` measures what the guard against it is
      worth instead: `Heap#scrub_force_parked` manufactures the state, and with
      the guard off the wipe reaches live frames **1 of 1** and the process dies
      (SEGV at 0x0 — the first time `fiber_scrub_live_frame_overlaps` has ever
      moved, so the counter is now known to work); with the guard on it is
      skipped and the canaries survive. Readable only because the skip is now
      counted — `fiber_scrub_midswap_skips` on `/gc-stats`. 30 runs identical,
      both gate directions broken on purpose and observed red.
      `docs/SOUND-DEFAULTS.md` § "What `scrub_fibers` costs", § "Auditing the scrub",
      § "The mid-swap window"
- [x] **The collector asked glibc about a thread it had suspended, and hung.** Found and
      fixed 2026-08-10 while building the mid-swap harness; unrelated to the
      scrub. `scan_other_thread_stacks` asked `pthread_getattr_np` for each
      thread's stack bounds *after* STW had frozen those threads — a call that
      locks the *target's* descriptor, which a suspended thread can be holding.
      The collector then waits forever with no crash and no output. Located by
      marker, inside that one call, on the third thread of the scan; the world
      itself stopped fine. Isolated afterwards against a positive control in the
      same binary: non-main threads **9 of 100**, main thread only **0 of 100**,
      `LibC.malloc` 64 KiB under STW **0 of 100**, `fopen` under STW **0 of
      100** — so it is the query about a frozen thread, not libc under STW. **Fixed** by snapshotting
      the bounds in `stop_world` under `Thread.lock` before the first suspend
      signal and doing a table lookup under STW
      (`Platform.snapshotted_stack_bounds`): same call count per collection, out
      of the suspension window. Measured (9950X/WSL2, EC4, one fiber holding a
      worker across the first collect): **18 of 150 starts hung → 0 of 500**, and
      **12 of 150** again when both hunks are reverted. `resize(4) + collect`
      alone never hung (0 of 200). Independently confirmed by the mid-swap
      harness, which needed a retry on ~8% of runs before and 0 of 15 after.
      Gate: `make stw-startup-hang`. Misses in the bounds table are counted
      (`pthread_bounds_misses` on `/gc-stats`) because a miss costs the
      pthread-mapping half of a thread's root coverage. Darwin needs none of it —
      `pthread_get_stackaddr_np` only reads the descriptor.
      `bench/log/linux/2026-08-10-stw-startup-hang/FINDINGS.md`
- [x] **Audit the rest of the STW body for libc calls.** Closed by measurement
      rather than by inspection, and it narrowed the rule instead of widening it.
      Allocation under a suspension is not the hazard: `LibC.malloc` 64 KiB × 8
      under STW is 0 of 100, `fopen` is 0 of 100, and the finalizer registry's
      `queue_pending` — which really does call `LibC.malloc` once per unreachable
      finalizable object with the world stopped, measured at ~1999 in one
      collection — is 0 of 150, all against a control firing at 4–9%. So the
      registry was **left alone**, as were `Platform.push_range`'s realloc inside
      `scan_static_roots` and the blacklist / chunk-index growth. The rule that
      survives is narrow — do not ask glibc about a suspended thread — and
      `pthread_getattr_np` was its only instance in the collect path.
- [x] **Make a hang under STW audible.** Done — `GCRY_STW_WATCHDOG_MS` arms a raw
      watcher thread (not a `Crystal::Thread`, or STW would suspend the one thread
      that has to keep running) which prints the stuck phase:
      `STOP-THE-WORLD STALLED 514 ms in phase=thread-stacks`. That line is from
      the *real* hang, reproduced with the fix reverted — it names the exact phase
      the bug was in, so the next one costs a line instead of a bisect. Gated by
      `make stw-watchdog` from both sides (fires on a deliberate stall, silent on
      an ordinary collection; both directions broken on purpose and observed red),
      and wired into CI along with the hang trap itself. Default off. Note
      re-signalling remains *not* the tool to reach for: `Thread#suspend` clears
      `@suspended` before it signals, so a re-signal can clobber an in-flight ack
      and create the hang it is meant to break.
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
- [x] **Apply the low-water skip to the `lag > 0` default path.** Done by
      ungating it: the default now starts at `max(stack_top − lag, low_water)`,
      bounded by the lag *and* clear of the untouched head. **Kemal EC4 pause
      8.06 → 3.60 ms** (−55%, root work −60%), RSS flat to 0.2%, `mark`/`sweep`
      unchanged — 9 paired reps, single heap regime, IQR 24%/12%
      (`bench/log/linux/2026-08-09-104417-root-phase/`). Fat app ~72 MiB:
      tuned **10.7 ms** against the old default's 28.8 ms and sound's 18.2 ms
      (`…-105503-`, softer — thread-count confound in its FINDINGS). The EC4
      control the item asked for is what proved it: `lag = 0` stays the wrong
      default there (16.4 ms), so the skip makes the *bounded* scan cheap, not
      the complete scan affordable. Kemal EC1 is unreachable by construction
      (`multi_mutator_threads?` false at 2 threads). Engagement is observable
      via `low_water_skips` on `/gc-stats` — the gate is a thread count a real
      app can sit on the boundary of.
- [ ] **Cheap root scan at scale — what is left.** `GCRY_SOUND=1` is still
      +83% pause at EC4 against tuned, and that residual is no longer a constant
      worst case: it tracks how much stack was actually touched (p5 3.4 ms,
      p95 19.1 ms, against tuned's 6.1/7.8). Open: which fibers are deeply used
      and why. **Closed:** the fat-app large-heap re-cut (above — the 14.5×
      was pre-fix and the sign has since reversed).
- [ ] **Low-water skip on Darwin.** Linux-only today, so macOS still faults the
      whole lag window per parked fiber and gets none of the EC4 win
      (8.06 → 3.60 ms there). The soundness argument needs a primitive that
      separates "never faulted" from "written then evicted" — residency alone is
      wrong, because a page that was written and later swapped reads absent and
      skipping it drops a root. That is why `mincore` was rejected on Linux, and
      it rules `mincore` out on Darwin too: macOS compresses and swaps.
      **Candidate:** `mach_vm_page_query` / `vm_map_page_query_info`, whose
      disposition bits include `VM_PAGE_QUERY_PAGE_PRESENT` **and**
      `VM_PAGE_QUERY_PAGE_PAGED_OUT` — the same present-or-swapped test pagemap
      gives, if those bits mean what they appear to. *Unverified: no Darwin host
      on this bench.* Before shipping it, port `spec/stack_low_water_spec.cr` —
      it pins the claim ("never reports above a written word") rather than the
      pause number, which is exactly the assertion a second implementation has
      to earn on its own.
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
