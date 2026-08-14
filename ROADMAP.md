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
- [x] Fat app (acikturkiye): Linux ~**90–96%** thr @ ~**1–1.6×** RSS (finalizer + retain=0; i3 ~1.63× / 9950X ~1.0–1.8×; was ~3.43× at v0.17); opt-in `GCRY_TIGHT_GROW` ~**103%** @ ~**0.92×**; Darwin tip ~**98%** @ ~**0.97×** at n=9 (2026-08-14 re-cut; was ~18× at v0.17. The ~0.63× carried before does not reproduce — gcry's RSS is within 0.6% of that cut and Boehm's arm is what fell 35%)
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
      any change to how Crystal spills. Now measured on a **second ABI**
      (aarch64, Darwin host, 2026-08-10): clean through **64**, corrupt at
      **72**, 3/3 reps per rung, every failure at address `0x0`. The prediction
      from `PARKED_AARCH64_SPILL_WORDS = 22` — a 176-byte boundary — is
      **falsified**; the constant is right but describes where the caller's SP
      lands, not which word must survive. Both platforms obey one rule: *the
      window ends immediately below the saved return address* (x86_64 +56,
      aarch64 +64, where `lr` is the ninth spilled word of twenty-two). x86_64
      alone could not distinguish that rule from "end of the spill block". No
      defect at the shipping window; no tolerance either. **The mid-swap suspend
      is now closed too**, and the
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
- [x] **gcry drops a live object under the probe compiler — Darwin never scanned
      a suspended thread's registers.** Fixed 2026-08-11. Found
      2026-08-11 on Darwin aarch64 while re-cutting the fat app. A live
      `String`'s tail is overwritten in place — `user_profile_picture` +
      `\0\0\0\0<` where `user_profile_picture_path` should be, same 25-byte
      length, head intact — so the allocation was freed and part of its storage
      reissued while still referenced. Always that same string. Surfaces as
      `DB::MappingException` and a `Non-2xx`, which is the only reason a
      benchmark caught it. **Both factors necessary, neither sufficient:** Boehm
      on the probe compiler 0/3, gcry on asdf 1.21.0 **0/23**, gcry on the probe
      compiler **2/5** without EC flags and **5/6** with them. **Not bisected —
      it predates the range tried:** `75a9d25`, taken as the good end because a
      2026-08-04 session showed no signature there, measures **8/10 corrupt** on
      re-test, and that session's evidence was 0/3 for the matching arm rather
      than the 0/15 first claimed (12 of those trials were `PRECISE_STACK`
      builds). There is no known-good commit, and the per-trial rate is too noisy
      (2/5 … 8/10 on arms that should match) to call one clean cheaply.
      **It requires a collection:** with `GCRY_DISABLE_AUTO=1` the same binary is
      **0/5** against its own 8/10 (verified zero collections during load), which
      rules out the competing reading that nothing is dropped and a neighbour
      overflows into exact size classes — the `eed00fb` shape. A live object is
      being reclaimed. **Root cause found:** `Platform.each_thread_greg` is an
      **empty stub on Darwin** (`darwin_stw.cr:135`, "full greg dump not wired
      yet") while `collect_scan.cr:513` calls it precisely because a suspended
      thread's registers "may hold the only live copy" — Linux implements it,
      Darwin yields nothing, so a reference living only in a register is not a
      root and its object is swept. Accounts for every observation, including the
      compiler dependence (register-vs-spill is a codegen choice) and why Linux
      never saw it. The state is already fetched: `sp_from_mach_thread` reads the
      full thread state and keeps only SP. **Fixed and A/B'd:** the same
      `thread_get_state` now feeds both, registers ungated by the SP-clamp knob,
      per-STW validity so a stale slot is never marked. At `75a9d25`, both arms
      back to back: plain **4/10**, fixed **0/10** (p ≈ 0.006). A first attempt
      at `d36effe` was discarded — 0/10 *both* ways, because the rate had drifted
      and the reverted arm produced no positive control.
      **Control re-established 2026-08-14** on probe compiler `656fc4620` (the
      A/B ran on `4a965f423`, and a codegen-dependent defect does not inherit a
      base rate across compilers): `75a9d25` plain is **7/10**, tip with the fix
      **0/10**, same host and morning (binomial vs a 0.7 base rate p ≈ 6e-6;
      Fisher ≈ 0.003). Those two arms differ by a commit range as well as by the
      fix, so the single-commit attribution is still the 4/10 → 0/10 above; what
      this adds is that the workload still produces the defect on the current
      toolchain, so a clean fixed arm is not a rate artefact. It also cost one
      wasted run: `acikturkiye/lib/gcry` is a **symlink to the main checkout**,
      so running the harness from a worktree selects the script, not the
      collector — the first "control" compiled against the fixed tree and its
      0/10 meant the opposite of what it was labelled.
      **Now gated** in `process_spec` and `make greg-roots` on a
      `thread_greg_candidates` counter (also on `/gc-stats`), verified red by
      stubbing the method out; the same gate runs on Linux x86_64 and aarch64.
      Still open: whether Linux has an analogous gap on any path — the gate
      above is what will answer it — and which compiler and gcry commit prod
      builds from, which is what would connect this to the 2026-08-08
      SIGSEGV, which remains an unproven bet.
      `bench/log/macos/2026-08-14-greg-control-75a9d25/FINDINGS.md`
      Ruled out: both precision axes (`GCRY_SOUND=1` 2/5,
      `+GCRY_DISABLE_LAYOUT=1` 4/5, both verified from `/gc-stats`), the scrub in
      **both** directions (forced on it is 4/5 and *worse* per trial), and thread
      count (2 under load either way). Open: which commit, which root, whether
      Linux reproduces, and which compiler and gcry commit prod builds from —
      that last is what would connect it to the unproven 2026-08-08 SIGSEGV.
      `bench/log/macos/2026-08-11-080733-acik-ec-isolation/FINDINGS.md`
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
- [x] **The EC Monitor ran inside the stopped world.** Found and fixed
      2026-08-11 while looking for the nightly soak SEGV. `stop_world` never
      signal-suspends the Monitor and assumed cooperative blocking in
      `allocate`/`lock_read`; measured, its loop reaches neither — it woke ~100×/s
      through a 4 s stop and ran `StackPool#collect` (munmap of fiber stacks)
      inside it, 250 µs, while the collector scanned thread stacks. Replaced the
      assumption with a handshake (`Gcry::MonitorGate`), shard-side via
      `previous_def` — **no compiler fork**, verified before relying on it. Both
      directions gated (`make stw-monitor-gate`); cost is now measured over a long
      run rather than a short one — **one wait of 263 ns in 3411 collections**
      (`stw_waits=1`), worst case one in-flight call, counted on `/gc-stats`.
      **It was not the nightly SEGV**, and that is now measured rather than
      unknown. `GCRY_MONITOR_GATE=0` restores the pre-fix behaviour and
      `GCRY_STW_TEST_STALL_MS` widens the stopped window on every collection, so
      the overlap can be manufactured instead of waited for: three control arms
      accumulated **438 overlaps** — ~340× the ~1.3 the crashing CI run had seen
      when it died — with no crash. The other half needs no soak, only a number:
      the thread-stacks phase is **30 µs** of a 2.76 ms pause, so a 5 s
      `collect_stacks` period expects one hit inside the scan every ~46 h, and
      that run died after 1.4 h. So the crash is **unattributed again**: what
      overwrote a pointer in `Parallel::Scheduler`'s queue is open.
      `bench/log/linux/2026-08-13-soak-segv/FINDINGS.md`,
      `bench/log/linux/2026-08-11-sysmon-runs-during-stw/FINDINGS.md`
- [ ] **What crashed the 2026-08-10 soak.** `Invalid memory access at
      0x7f1700000149` inside `Parallel::Scheduler#quick_dequeue?`, 1h24m in — a
      heap pointer with its low bytes overwritten, i.e. a slot freed and reused
      while the scheduler still pointed at it. The standing candidate (the EC
      Monitor running inside the stopped world) is now **excluded by rate**, so
      nothing explains it. Two things that were in the way are gone: the soak can
      now finish in CI at all (it asked for 24 h on a 6 h job), and a crashing run
      keeps its telemetry. Next: reproduce with the 5 h CI arm, and consider
      whether anything else mutates scheduler state outside the collector's view.
      `bench/log/linux/2026-08-13-soak-segv/FINDINGS.md`
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
- [ ] **Cheap root scan at scale — what is left.** The EC4 residual is
      `GCRY_SOUND=1`'s, and quoting it as a ratio has become misleading twice
      over. **9950X, before the default path got the skip:** tuned 7.1 ms,
      sound 13.0 ms — **+83%**. **i3-12100F, after:** tuned 3.60 ms, sound
      16.39 ms — **+356%** (`bench/log/linux/2026-08-09-104417-root-phase/`).
      Different hosts, so the absolute numbers do not compare; but the *ratio*
      grew mostly because the denominator halved, not because `sound` got
      worse — lag 0 already had the skip and did not change. Cite the pair, not
      the percentage.
      What is genuinely open is the same as before: sound's cost tracks how much
      stack was actually touched, so its distribution is wide where the old flat
      scan's was not (9950X: p5 3.4 ms, p95 19.1 ms). **Which fibers are deeply
      used, and why** — `low_water_skipped_bytes` per collection is now the
      handle for that, and did not exist when the question was written.
      **Closed:** the fat-app large-heap re-cut (above — the 14.5× was pre-fix
      and the sign has since reversed).
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
      gives, if those bits mean what they appear to. *The disposition bits are
      still unverified*, but the bench gap is closed: a Darwin host cut Kemal
      and the fat app under current defaults on 2026-08-10
      (`bench/log/macos/2026-08-10-053800/`, n=9), and `low_water_skips = 0` in
      every draw confirms Darwin takes none of the Linux win rather than
      assuming it. That is the **baseline** this item needed — without one, an
      implementation could not say what it bought. Before shipping it, port
      `spec/stack_low_water_spec.cr` — it pins the claim ("never reports above a
      written word") rather than the pause number, which is exactly the
      assertion a second implementation has to earn on its own.
- [ ] **`make invariants` has never passed on Darwin.** `GCRY_DEBUG_INVARIANTS=1`
      fails `spec/collect_spec.cr:202` ("keeps empty chunks dormant within
      empty_chunk_retain") with `live_objects mismatch: actual=6364 reported=1`.
      Found 2026-08-14 running the suite locally on a Darwin host for the 0.19.0
      release; it is **not new** — the same failure reproduces at `master`,
      **`v0.18.0` and `v0.17.0`**, so it shipped in two releases unnoticed. It is
      unnoticed because nothing runs it: Linux CI has a "Debug invariants" step
      and is green, and `test-macos` runs `spec` / `process_spec` / samples only.
      Debug-only — the shipping path does not call the checker, and the same spec
      passes under `make spec`, so what disagrees is the walker and not the
      collector's own accounting. **Hypothesis, not a finding:**
      `Invariant.count_live_blocks` walks dormant chunks and counts any block
      whose header does not read free, and Darwin's reclaim leaves those headers
      alone (`MADV_FREE_REUSABLE` does not zero them — `collect_sweep.cr:439`),
      where Linux's `MADV_DONTNEED` does not leave the same residue. What would
      settle it: count what the walker sees on a chunk the sweep has just made
      dormant, on both platforms. Until then this is "the checker and Darwin
      disagree", which is worth exactly as much as that.
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
