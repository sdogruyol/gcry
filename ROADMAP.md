# gcry Roadmap: Aims to become Crystal's default GC

gcry is a conservative mark-sweep garbage collector written in Crystal, shipped as a shard.
This roadmap shows where we are and where we're going — from a shard that replaces Boehm
at build time, aiming toward a future where Crystal ships with its own GC.

## Current (v0.19.0) — "Suspended-thread register roots, on both platforms that lacked them"

- [x] **Suspended threads' GP registers are scanned everywhere the collector
      claims to support.** They were not: Darwin's `each_thread_greg` was an
      empty stub, and Linux **aarch64** returned nothing (`UCONTEXT_NGREGS = 0`,
      "for now"), while `collect_scan` called both. A reference the compiler
      kept in a register and never spilled had no root, and its object was
      swept. Gated by `thread_greg_candidates` in `process_spec` and
      `make greg-roots`, on Darwin + Linux x86_64 + Linux aarch64 — the aarch64
      half was found by that gate on its first CI run

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

## Next (v0.20.0) — "Prove root coverage, and put Darwin under the gates"

Both defects v0.19.0 closed were the same shape: a root the caller assumed was
scanned and the platform returned nothing for — Darwin's empty `each_thread_greg`
stub, and Linux aarch64's `UCONTEXT_NGREGS = 0`. Neither was visible until a
counter was wired to a gate and the gate was broken on purpose. The largest open
item fits that shape too, so 0.20.0 spends its budget on root coverage and on the
CI asymmetry that hid both.

- [ ] **Audit root coverage for the EC Parallel scheduler.** The 2026-08-10 soak
      SEGV is a slot freed and reused while `Parallel::Scheduler` still pointed at
      it (open below), i.e. a missed root — and its only named candidate is now
      excluded by rate, so nothing explains it.
      **The instrument exists now**: `ec_root_pins` on `/gc-stats` counts the
      structures `scan_thread_roots` pins by name, and `make scheduler-roots`
      gates on it as a delta across a collection taken before the context exists,
      so the ambient Thread-level pins cannot carry the arm. Both directions
      broken on purpose and observed red (stub → 7 of 16 named; reset removed →
      control off zero). It runs on all three platforms that have a CI job.
      **Two candidates eliminated, no root cause yet.** The macro gate on
      `Thread.@execution_context` is **open** on the configuration the soak builds
      — measured on 1.21.0: open by default and under `-Dexecution_context`,
      closed only under `-Dpreview_mt`, where the pre-EC scheduler means there is
      nothing to pin — so the block is not compiled out there. And the
      precise-offset path did drop ivars it could not classify, but that path only
      installs under `GCRY_AUTO_LAYOUTS=1`; the default `register_scan_caps`
      installs a cap and no offsets, so the scan stays conservative and covers the
      slot. The soak sets no such flag.
      **That second candidate is now settled as a defect in its own right, and
      fixed** (Phase 3 below, and `bench/log/linux/2026-08-15-ivar-layout-drop/`):
      an ivar that is neither Reference, Pointer, pointer-safe union,
      Value-with-ivars nor StaticArray got no offset *and* no conservative
      fallback, so its word was never scanned — 19 such ivars in 186 stdlib types,
      `Fiber#proc` among them. It is **not** an explanation for the SEGV, and the
      ivar it was recorded against is not an instance: `Crystal::EventLoop` is an
      abstract *class* on 1.21.0, so `@event_loop` was always emitted, and every
      ivar of `Parallel::Scheduler` classifies.
      **The list is now complete by construction** (2026-08-15). The block pinned
      seven names; the structures carry **ten pointer ivars on the context and
      seven on the scheduler**, so `@mutex`, `@condition`, `@rng`, `@next`,
      `@previous`, `@name`, `@thread` and the scheduler's own `@global_queue` /
      `@event_loop` were covered only by the conservative body scan the pin block
      exists because it does not trust. `pin_ec_ivars` now derives the pins from
      `instance_vars` at compile time — a list drifts, `instance_vars` cannot —
      and marks **every word** of any slot that is not plainly a `Reference`,
      because `sizeof(Fiber::ExecutionContext | Nil)` is 16 on 1.21.0 and pinning
      "the pointer word" would have pinned the type_id and looked covered.
      45 named slots per collection for a 4-worker context against the old 16.
      `make scheduler-roots` computes its expectation from the same
      `instance_vars`, so an upstream addition moves both sides together; the
      residue — a pointer-bearing ivar narrower than a pointer, which has no sound
      answer — is counted by `ec_root_unpinned_ivars` and asserted zero. Both arms
      broken on purpose and observed red.
      **And the dispatch into that list was itself a name.** `if ec.is_a?(Parallel)`
      — there are two context types on 1.21.0, so an `Fiber::ExecutionContext::Isolated`
      contributed **3 pins**, all ambient per-thread ones, and its `@main_fiber`,
      `@thread`, `@wait_list` and the user's `@func` closure had no explicit pin
      at all (15 slots; 18 pins after). Now dispatched over
      `Fiber::ExecutionContext.includers` + subclasses, most-derived first, with
      an Isolated arm in `make scheduler-roots` and the queue audit asking the
      type whether it has queues rather than naming Parallel. It meets the layout
      item below: `Isolated#func` and `#spawn_context` are two of the 19 dropped
      ivars, so under `GCRY_AUTO_LAYOUTS=1` that closure had neither route.
      `bench/log/linux/2026-08-15-isolated-context-unpinned/FINDINGS.md`
      **Still open, and the reason this item stays unchecked:** none of this
      explains the 2026-08-10 soak SEGV. `Isolated` is opt-in and the soak uses
      plain `spawn`, so it cannot have hit that hole either. The soak sets no `GCRY_AUTO_LAYOUTS`, so
      those ivars were reached conservatively there anyway — what changed is that
      they no longer depend on it.
      `bench/log/linux/2026-08-15-ec-pin-completeness/FINDINGS.md`
- [ ] **Make the soak reproducible enough to bisect.** One 5 h arm a week cannot
      chase a crash that took 1h24m to arrive: at that cadence a candidate fix is
      indistinguishable from a quiet run inside a release cycle. Two handles were
      named; **the second is now built.** `GCRY_EC_QUEUE_AUDIT=1` walks the ring
      and the global list inside STW at every collection and names the first one
      that holds something other than a live Fiber — structure, index and value —
      instead of waiting for the dequeue to SEGV on it. Gated by
      `make ec-queue-audit` (the report must name the *planted* value, which is
      what separates a working type check from a walk that trips one hop later),
      on for the CI soak, and carried per hour in the soak telemetry as
      `queue_slots` / `queue_faults`. Also settled on the way: the **default**
      execution context is `Parallel` on 1.21.0 with or without EC flags, so this
      and the pin block cover ordinary `spawn`.
      **Both handles are now built.** Exposure was the gap the audit left: the
      baseline workload spawns at ~10 Hz against ~1 collection/s, so **1
      collection in 24** had a non-empty queue when the world stopped, and the
      audit can only catch a slot that is corrupt *while* a collection sees it.
      `--fiber-churn=N` (default **0**, the baseline every earlier soak ran on)
      spawns N fibers per 1 ms burst that yield four times each; at **512** it is
      **23 of 24** collections, 2486 slots, max 508. The audit's cost measured at
      that occupancy rather than at zero: p50 8.41/8.34/8.77 ms on against
      8.29/8.58/8.67 ms off. Churn moves RSS +44.7 MB (stack pool), so the soak
      **refuses** a churn run whose `--rss-limit-kb` is still the baseline +4 MB
      instead of failing on a bound nobody chose. And the CI soak is now a
      `fail-fast: false` matrix of **three concurrent arms** — one arm a week
      cannot chase a 1h24m crash, and an arm that dies must not cancel the two
      that might have died differently — with `fiber_churn` /
      `soak_rss_limit_kb` as dispatch inputs, both defaulting to the baseline.
      **Why the item stays open:** no fault has been reproduced. This raises the
      rate at which a run could catch one (1/24 → 23/24 collections, ×3 arms) and
      shortens the report from "an hour later, in the consumer" to "the next
      collection"; whether that is enough is the next scheduled run's answer.
      **And a crash explains itself** (`GCRY_SEGV_REPORT=1`, on for the CI soak):
      the faulting address is checked against the heap's own tables — in the span
      or not, which block, used or free, what its first word is — and the poison
      is looked for in the faulting context's registers, because
      `0xdeadf2ee…` is non-canonical and the kernel reports `si_addr` as 0 for
      it. Gated by `make segv-report`, one forked child per fault shape. Two
      lessons are in the code because the first versions were wrong: installing
      at `GC.init` is discarded by Crystal's own handler, and matching the poison
      on the address never fires.
      **And freed blocks can be poisoned** (`GCRY_POISON_FREED=1`, on for the CI
      soak): a freed payload becomes `0xdeadf2eedeadf2ee`, so the next crash of
      this shape says use-after-free instead of leaving another plausible hex
      value to argue about. Gated by `make poison-freed`, whose second arm is the
      dangerous half — poisoning must not defeat the freelist-clean fast path, or
      a cleared `malloc` hands out poison (broken on purpose: 10560/10560 words).
      Costs **+40% on the soak's pause** (2.72 → 3.81 ms p50, n=5), which is why
      it is opt-in.
      The audit now also checks the **structures**, not only their slots: a
      reissued `Runnables` makes every slot garbage rather than one slot bad, so
      the slot walk could not have reported the very shape the SEGV is read as.
      Each ivar with a concrete Reference type must be a live object of that
      type, and a container that fails is not then walked.
      `bench/log/linux/2026-08-15-ec-queue-audit/FINDINGS.md`,
      `bench/log/linux/2026-08-15-soak-churn-arms/FINDINGS.md`
- [x] **Fix `make invariants`, and run it on Darwin.** Done 2026-08-15 — and it
      was never a Darwin problem: the walk counted every block of a **dormant**
      chunk (headers the sweep has advised away read as neither used nor FREE on
      either platform), and `spec/mt_spec.cr:118` was a *race* against concurrent
      mallocs rather than a drift. 163 examples, 0 failures. Detail in Phase 3
      below; `GCRY_DEBUG_INVARIANTS=1 crystal spec` now runs in the macOS job, and
      both cases are pinned by `spec/invariant_spec.cr` without the env var.
- [x] **The Ameba gate lints gcry now.** It linted **ameba's own 346 files** on
      every green run on record: the CI step `cd lib/ameba`'d to build the binary
      and never came back, so it ran with the working directory inside ameba's
      checkout and never loaded gcry's config. `make lint` was always right; CI
      calls it now. The first honest run found 10 issues, and four of them were
      `Lint/SpecFilename` on `spec/regression/*.cr` — four regression tests, one
      per historical GC defect, that **`crystal spec` had never run** (it collects
      `*_spec.cr`). Making them run showed something worse: they call `GC.malloc`
      / `GC.collect`, and gcry only takes over `GC` under `-Dgc_none`, which
      `spec/` does not pass — measured, three `GC.collect` calls move gcry's
      collection count 0 → 0. **They were testing Boehm**, in every job that ran
      them. Moved to `process_spec/regression/` (13 → 17 examples, Linux and
      Darwin), where one promptly failed on a threshold calibrated against the
      vacuous run and now asserts the drift the defect actually produced.
      `bench/log/linux/2026-08-15-ameba-linted-ameba/FINDINGS.md`
- [ ] **Close the Darwin CI asymmetry.** It is why the items above were open.
      `test-macos` runs `spec`, `process_spec`, the samples, `make greg-roots`,
      `make scheduler-roots`, `make ivar-layout-roots`, `make ec-queue-audit`,
      `make perf-baseline`, and — all added 2026-08-15 — **Debug invariants**
      (exactly what hid the item above for three releases),
      **`stw_mt_property_test`** and a **soak smoke**.
      The soak needed a Darwin RSS reader before it could run there at all: its
      `/proc/self/status` reader returned 0 under a `rescue`, so the RSS ceiling
      compared 0 against a start of 0 and passed by measuring nothing.
      `bench/bench_rss.cr` reads `task_info(MACH_TASK_BASIC_INFO)` instead, is
      shared by the three harnesses that each had their own copy, and returns
      **nil rather than 0** so a caller that gates on RSS refuses instead. Two
      consistency checks on the Darwin read (`resident != 0`, `resident_max >=
      resident`) turn a wrong struct offset into "cannot answer" rather than a
      plausible wrong number. Cross-compiled for `aarch64-apple-darwin` to
      type-check the mach path; not yet *run* on a Darwin host.
      Still missing: a **perf gate** (needs wrk on the macOS runner, and a
      baseline recorded there — see the item below). And the Darwin soak smoke is
      `continue-on-error` for now: its +4 MB RSS ceiling was measured on Linux,
      Darwin reclaims differently, and inventing a Darwin number would be exactly
      the thing this board refuses. The first runs set it, and then it gates.
- [ ] **Benchmark regression alerts** (Phase 2, pulled forward). `perf-smoke` gates
      on fixed floors — thr ≥65%, RSS ≤1.25×, p50 ≤2.5 ms — so a regression that
      lands inside the floor is invisible, and the floors sit far below tip
      (~85% @ ~0.8× @ ~0.6 ms). Compare a PR against a stored baseline instead, and
      against the measured noise floor (±2–3pp on phase timings, ±1pp on post-GC
      RSS at 12 reps — open below), not against zero.
      **The comparator is built and gated; the baseline is not recorded.**
      `bench/perf_compare.py` compares a run's `summary.json` against
      `bench/baseline/perf_smoke.json` on the four ratio metrics, and runs at the
      end of `perf_smoke.sh`. Its design turns on one rule: a baseline gates only
      if it carries a **tolerance derived from measured spread** — recording needs
      ≥3 runs, and with fewer it writes no tolerance and the file reports instead.
      `make perf-baseline` gates the comparator itself on fixtures (a regression
      in each metric's direction, an improvement, a within-noise run, both gate
      modes, a tolerance-less baseline and the unrecorded file the repo ships), so
      it is covered without wrk or a quiet host.
      **What is left is the number, and it is the hard half.** No baseline is
      recorded because none has been measured on the runner class that would use
      it, and the perf job's own comment records **~68–88%** thr across runs
      there — a spread that makes a tight gate flaky and an honest gate wide.
      Next: collect the `summary.json` files that job already uploads from N green
      pushes to master, `--record` from them, commit the file, and set
      `PERF_GATE_BASELINE=1` once the recorded tolerance is narrow enough to be
      worth blocking a PR on.

## Then (v0.21.0) — Darwin performance parity

Linux took an 8.06 → 3.60 ms EC4 pause from the low-water skip and macOS takes none
of it. The gap is measured rather than assumed — `low_water_skips = 0` in every
draw of `bench/log/macos/2026-08-10-053800/` — which is what makes it schedulable.

- [ ] **Low-water skip on Darwin** — open below. The first blocker is not code: the
      `mach_vm_page_query` disposition bits are still unverified, and residency
      alone is the wrong test (a page written then swapped reads absent, and
      skipping it drops a root). **The experiment now exists**:
      `make darwin-page-query` / `bench/darwin_page_query.cr` carries the
      candidate predicate and five arms — untouched pages must read skippable,
      written ones must not, every skippable page must read back zero, an
      `MADV_FREE_REUSABLE` page must read zero whatever its bits say, and a page
      that leaves residency with its contents intact must not read skippable.
      It runs in the macOS job. Type-checked by cross-compiling for
      `aarch64-apple-darwin`; **not yet run on a Darwin host**, so no bit is
      verified yet. Expect the eviction arm to come back INCONCLUSIVE from a
      runner that will not compress — the probe exits 0 and says so rather than
      claiming a pass it could not produce (`PAGE_QUERY_PRESSURE=<MiB>` forces
      the attempt).
- [ ] **Which fibers are deeply used, and why** — open below. `GCRY_SOUND=1`'s cost
      tracks touched stack, so its distribution is wide (p5 3.4 ms, p95 19.1 ms);
      `low_water_skipped_bytes` is the handle and postdates the question.
- [ ] **Attribute the residual per-rep spread** — open below. Until it closes it
      bounds every perf claim either release makes: ±2–3pp on phase timings, ±1pp
      on post-GC RSS, at 12 reps.

## After that — lift the ceiling

- [ ] **Compiler stack maps** (Phase 2). Shard-only levers for EC1 `/json` ≥95% @
      ≤1.0× RSS are **exhausted** (i3 + 9950X hunt MISS), so this is the only one
      left. It should end in a decision rather than an implementation: either
      precise roots pay measurably, or `GCRY_PRECISE_STACK` stays research and the
      ≥95% target is restated.
- [ ] **Write barrier** (Phase 2) — precondition for a sound concurrent /
      incremental backend, and therefore for "nursery + incremental on by default"
      (Phase 3). Ordering, not a new item.
- [ ] **Windows process GC** (Phase 2) — `src/gcry/platform/` is `linux_*` and
      `darwin_*` only. The widest good-first-issue surface on the board.

Ecosystem work runs alongside and blocks none of the above: the `-Dgc_gcry`
compiler PR, production dogfood (which would also settle **which compiler and gcry
commit prod builds from** — open below, and the missing link to the 2026-08-08
SIGSEGV), the leaderboard, and per-release write-ups.

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
- [x] **A precise layout could skip an ivar and still call itself precise.**
      Found and fixed 2026-08-15, out of the scheduler-root audit above, which
      could not settle it — the explicit pins cover the scheduler graph whether
      or not the layout drops an ivar, so that harness is green either way.
      `Layout.register` sorts each ivar into a scan offset, a noscan offset, or
      `force_scan_cap`; an ivar that is none of `Reference`, `Pointer`, a
      pointer-safe union, a `Value`-with-ivars or a `StaticArray` reached none of
      the three, so the entry installed as **precise** with the word omitted and
      nothing ever read it. Measured on both shapes that ship — a module-typed
      ivar, and a `Proc` whose second word is the only pointer to the closure's
      environment — each **swept** before the fix and live after, on both
      registration routes (explicit and `GCRY_AUTO_LAYOUTS=1`), against a
      Reference-typed control that survives either way. **19 dropped ivars in 186
      stdlib types** for a `json`/`http/server`/`socket` program, `Fiber#proc` and
      `Thread#func` among them: under auto layouts a fiber's captured environment
      had no root *from the fiber*, and survived only by the fiber's own stack and
      its spawner. Fixed by adding `has_inner_pointers?` to the fallback — the
      predicate `register_hash` already applies to its key and value types, and
      the plain-ivar walk beside it did not. Strictly more conservative: 9 of the
      186 move precise → `scan_cap`, none the other way, and the scan mix on the
      `json_churn` shape is unchanged (4012/45 both directions). Gated by
      `make ivar-layout-roots` on all three CI platforms; the gate is the
      installed entry, which is static, not the survival, which codegen could
      carry. Correction it forced: `@event_loop : Crystal::EventLoop`, recorded
      2026-08-14 as the shipping instance, is an abstract *class* on 1.21.0 and
      was never dropped.
      `bench/log/linux/2026-08-15-ivar-layout-drop/FINDINGS.md`
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
      **Linux had the same gap, on aarch64 — answered by the gate on its first
      CI run.** `linux_stw.cr` set `UCONTEXT_NGREGS = 0` there under the comment
      "skip full mcontext register dump on aarch64 for now (SP clamp only)",
      so `each_thread_greg` yielded nothing while `collect_scan` called it:
      the same dropped-root defect Darwin had, by a different route. x86_64
      (`NGREGS = 23`) was never affected. Fixed by giving aarch64 its real
      offsets — `regs[0]` at `uc_mcontext + 8` = **184**, **31** words x0…x30 —
      cross-checked against a constant already known good rather than trusted
      alone: `sp` follows `regs[30]`, so `184 + 31*8 = 432`, the SP offset the
      aarch64 clamp already runs on.
      Still open: which compiler and gcry commit prod builds from, which is what
      would connect this to the 2026-08-08 SIGSEGV, which remains an unproven
      bet.
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
- [x] **`make invariants` has never passed — and it was never a Darwin problem.**
      Fixed 2026-08-15. Two failures, two causes, neither platform-specific.
      (1) `count_live_blocks` walked **dormant** chunks, whose headers the sweep
      has advised away — Linux zeroes them (`flags == 0` is not FREE) and Darwin
      leaves them stale (also not FREE), so both read as live. The decisive
      experiment the item asked for, run on Linux: 4 dormant chunks, **6 501
      blocks counted against `live_objects = 1`**, of which 6 348 headers read
      all-zero and 153 stale. A dormant chunk is empty by construction (the sweep
      sets DORMANT only `unless any_live`) and the sweep already skips them, so
      the walker was the last reader that believed those headers.
      (2) `spec/mt_spec.cr:118` is a **race**, not a drift: `after_malloc` runs
      outside the allocation lock, so with four threads allocating the walk and
      the counter are different instants — `actual=40 reported=41`, off by the one
      allocation in flight. Skipped when more than main+monitor threads exist, and
      the skip is counted (`Invariant.concurrent_skips`) rather than silent.
      **163 examples, 0 failures** — first green run recorded. Both halves broken
      on purpose and observed red separately; both pinned by
      `spec/invariant_spec.cr` under plain `crystal spec` (no env var), so they
      gate on every platform including Darwin, and
      `GCRY_DEBUG_INVARIANTS=1 crystal spec` is now a step in the macOS job.
      Open: whether Darwin has a *third* failure behind these two — no Darwin host
      was available, and that CI run is what will say.
      `bench/log/linux/2026-08-15-invariants-dormant-walk/FINDINGS.md`
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
