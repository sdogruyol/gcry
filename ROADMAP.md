# gcry Roadmap: Aims to become Crystal's default GC

gcry is a conservative mark-sweep garbage collector written in Crystal, shipped as a shard.
This roadmap shows where we are and where we're going — from a shard that replaces Boehm
at build time, aiming toward a future where Crystal ships with its own GC.

**Release state.** Latest release **v0.26.0** (2026-09-15) — the headerless
layout as the compile default, plus the main-thread TLS roots on all three
platforms. The tip is the next candidate; `CHANGELOG.md`'s `[Unreleased]`
section is what it holds.

The headings below carry **no version numbers on purpose**. They are work
buckets, and every attempt to number them has rotted: v0.20.0 through v0.25.0
all shipped while this board was being written, and until 2026-09-15 the
headings still called v0.20.0 "current" and v0.21.0 "next" — six releases
after both had shipped. Every `[x]` carries the date it closed, and
`CHANGELOG.md` maps dates to releases; that pairing, not a heading, is the
record.

## Shipped (v0.19.0) — "Suspended-thread register roots, on both platforms that lacked them"

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

## Current — "Prove root coverage, and put Darwin under the gates"

Both defects v0.19.0 closed were the same shape: a root the caller assumed was
scanned and the platform returned nothing for — Darwin's empty `each_thread_greg`
stub, and Linux aarch64's `UCONTEXT_NGREGS = 0`. Neither was visible until a
counter was wired to a gate and the gate was broken on purpose. The largest open
item fits that shape too, so this bucket spends its budget on root coverage and
on the CI asymmetry that hid both. It has held that theme across v0.20.0 to
v0.25.0 and still does: the main-thread TLS roots and the Darwin `__mcontext`
reader closed here on 2026-09-15, and the Darwin CI asymmetry below is what
kept finding the rest.

- [x] **Thread-local storage was not a root, on the main thread — fixed
      2026-09-12.** A block whose only reference was a main-thread
      `@[ThreadLocal]` was **collected**. `dl_iterate_phdr` gives the
      executable's writable `PT_LOAD` segments, so every class variable is a
      root; a thread-local is in none of them — `PT_TLS` is only the template
      and the live block is per thread. What hid it is that the placement is
      not uniform: glibc puts a *spawned* thread's block at the top of that
      thread's own stack mapping, inside the bounds `pthread_getattr_np`
      reports and above the suspend SP, so the ordinary stack scan covered
      every thread gcry or Crystal spawns. The **main** thread's block is
      allocated with the shared libraries, nowhere near its stack — measured,
      tls `0x7f9db13e0770` against a stack of
      `[0x7ffc1e8e9000, 0x7ffc1f0e6000)` — and nothing scanned it.
      This is the third branch of the sentence `GCRY_POISON_HOLDERS=1` prints
      on every use-after-free this heap produces ("in a register, in
      thread-local storage, or in memory gcry never mapped"), and the only one
      that had never been tested. Registers were closed on the same day.
      Fixed by adding the block to the static root ranges at `GC.init`, on the
      main thread — the only context that can take the address of its own
      thread-local. **Sized from the executable's own `PT_TLS` `p_memsz`: 128
      bytes, not the 824 KiB mapping that contains it.** The first version
      took the mapping and that is ~100k words of conservative scan per
      collection, retaining whatever they look like. `make tls-roots`, three
      arms: shipped keeps the block, `GCRY_TLS_ROOTS=0` loses it, and a
      control holding the pointer nowhere loses it either way — without the
      control a stale stack slot passes the first two.
      `bench/log/linux/2026-09-12-tls-not-a-root/FINDINGS.md`

- [x] **The same question on Darwin and Windows — closed 2026-09-15.**
      Linux located the live block via `/proc/self/maps` and sized it from
      `PT_TLS`. Darwin's live TLV is a libc malloc in no `__DATA` section
      the dyld walk takes (`_tlv_bootstrap`); Windows copies `.tls` per
      thread through the TEB, and the main thread uses the template in
      place. Both now add the live range the same way Linux does: size
      from the image's TLS geometry (`__thread_data`+`__thread_bss` /
      PE TLS directory), clip with `mach_vm_region` / `VirtualQuery`,
      skip the template as a static root. `make tls-roots` is the gate
      (`GCRY_TLS_ROOTS=0` must lose the block; `--control` must die
      either way). Darwin CI and the Windows default variant run it.
      `bench/tls_roots.cr` uses `current_pthread_stack_bounds` so the
      stack-bounds line is not Linux-only.

- [x] **A use-after-free in fiber creation — closed in v0.20.0.** The root it
      needed is the stack of a fiber that is *ending*: `Thread#dying_fiber`
      parks it, the owning `Fiber` is already out of the fiber list, and the
      thread may still be running on it. Interleaved, poison on: **10/24
      crashes → 0/24**, with a twin arm that walks the same memory and offers
      nothing at 12/24; 5 h soak × 3 arms clean (~52 000 collections, ~526 000
      fibers, 0 errors). What follows is the hunt that got there, kept because
      four of its readings were wrong and the corrections are the useful part.
      **The thread family below is a different defect and is still open.** `bench/nested_spawn_uaf.cr`:
      spawn fibers on an explicitly created `Fiber::ExecutionContext::Parallel`
      and collect underneath them. With `GCRY_POISON_FREED=1` it crashes in
      `Fiber#initialize` → `makecontext` on **~19 runs in 20**; under **Boehm,
      same file, 0 in 25**, so the collector is the subject and not Crystal's
      execution context. It is a real use-after-free and not a poison artifact —
      120 000 cleared allocations were checked and none came back poisoned.
      **The block is named.** `GCRY_POISON_TAG=1` (added for this) writes the
      freed block's address into the poison, and across 40 crashes the sizes are
      384 / 768 / 1536 / 3072 — `Fiber::Stack` is 24 bytes, so 16 / 32 / 64 / 128
      entries, the capacity sequence of a `Deque(Fiber::Stack)` — always
      `still FREE`. It is `Fiber::StackPool`'s deque buffer, and specifically a
      buffer the deque **abandoned at a resize**, not the one it is using (gcry
      never frees the current one: 0 dead in 4 800 checks).
      **Two independent interventions take it to zero**, which is what pins the
      mechanism: pre-grow the pool so it never resizes (**0/20**), or never
      release the root `Heap#realloc` takes on the old block (**0/20** against
      20/20 in the same batch).
      **What does not work**, and rules out the easy fix: releasing that root a
      bounded number of collections later. A grace list at 1, 4, 16 and 64
      collections, at 512 and 65 536 slots, all still crash — so the stale
      pointer is held *indefinitely*, and the root-set inflation of those arms
      also rules out "removing `delete_root` merely changed timing". The grace
      machinery was written, measured and reverted.
      **The holder is now named, and it is one level above the buffer.**
      `GCRY_POISON_HOLDERS=1` searches the root set, every live block and every
      fiber stack for the freed block's address at fault time
      (`src/gcry/poison_holders.cr`, gated by `make poison-holders`, both
      directions broken on purpose and observed red). Across **17 crashes in 37
      runs** it says the same thing every time: **exactly one** heap holder — a
      **32-byte block, `type_id` 210 = `Deque(Fiber::Stack)`, holding the
      pointer at +16, which is `Deque`'s `@buffer`** — and **0 of 0** explicit
      roots. Every stack holder sits on a **running** fiber *above* `stack_top`,
      i.e. inside the window the collector scans, so a stack-scan hole is
      eliminated rather than left open.
      **And one level up names the owner: it is the context's own stack pool.**
      The search now runs a second pass against the holder itself, and the
      harness prints the live pools' addresses before anything can go wrong, so
      the match is by address and not by inference. Across 7 crashes: the freed
      block's only holder is `live ec pool deque`, and *its* only holder is
      `live ec pool` — `type_id` 199 = `Fiber::StackPool`. Not an orphan, not a
      duplicate, not the default context's: the pool the program is spawning on.
      **And the deque is not mid-resize.** The holder's payload is dumped, and
      `@capacity` matches the freed block's entry count exactly — 1536 B ↔ 64,
      3072 B ↔ 128, with `@size` below it. `Deque#resize_to_capacity` writes
      `@capacity` before `@buffer`, so that race would show a capacity *larger*
      than the block `@buffer` points at. It does not, which also retires the
      "buffer abandoned at a resize" reading: the freed block is sized to the
      deque's live capacity.
      **Correction to the first cut of this item.** It read a zero mark
      generation as "no collection ever marked the holder" and concluded the
      buffer was freed because its owner was unmarked. That was wrong: `sweep`
      clears every survivor's mark (`collect_sweep.cr:127/146/347`), so between
      collections every live object reads zero — measured against an object held
      in a local across three collections. The verdict is out of the reporter;
      raw flags stay, and `ATOMIC` is called out by name because *that* bit does
      mean the payload is never scanned. Neither the pool nor the deque is
      ATOMIC.
      **And the answer is that no heap edge is missed at all.** Three
      measurements, at `ROUNDS=20 FIBERS=64` (the repro is **20× cheaper** than
      documented: 4/12 crashes at ~2 s a run against 6/15 at ~40 s):
      (1) `BlockHeader::Flags::SWEPT` — a new diagnostic bit set by the sweep's
      freelist link and clear on an explicit `Heap#free` — says the block was
      freed **by the sweep**, so the collector decided it was garbage;
      (2) nothing changes the rate — `GCRY_SOUND`, `GCRY_INTERIOR`,
      `GCRY_AUTO_LAYOUTS`, an explicit root on the pool, on the deque (verified
      live: the report reads `explicit roots: 0 of 3`), on the buffer, or never
      releasing a root on `realloc`'s *new* block (written, measured, reverted);
      (3) `GCRY_MARK_AUDIT=1` walks every marked block between mark and sweep and
      reports any pointer into a block about to be freed — **zero missed edges**
      across 15 runs and 6 crashes, ~31 000 base edges per short run. Gated by
      `make mark-audit`, whose `hold` arm plants an edge the mark provably does
      not follow (a pointer in a block's `scan_cap` slack under
      `GCRY_SCAN_CAPS=1`) and requires it to be named: 199 missed of 1579,
      against 0 of 1977 clean and 0 edges with the knob off. Also broken on
      purpose at the source: stubbing `mark_candidate` gives 1 missed of 235.
      **So the window is "nothing points at it yet".** The block was freed by the
      sweep, no marked object pointed at it then, and the live deque points at it
      now — so the deque acquired the pointer *after* the collection that freed
      the block, and at that collection the block was live only in a register or
      a stack slot. That moves the hunt off heap edges and onto **ambient roots
      of the allocating thread**.
      **The birth grace closes it, and names what dies.** `GCRY_BIRTH_GRACE=1`
      (research only) roots every block `allocate` returns for the next
      collection and drops it after: **20/48 → 0/48**, in back-to-back batches,
      with `birth_grace_rooted` 2 774 and **0 overflows** so a null result could
      not have been a silent cap. It runs *after* the mark, so it reports each
      newborn block the mark did not reach before saving it — and across six runs
      **157 of the reported saves are one thing: size 192, first word 0xa8, i.e.
      `type_id` 168 = `Fiber`**. A `Fiber` in the middle of `Fiber#initialize` is
      reachable from no root the collector scans, which is the same call the
      crash dies in, and why the repro's nesting matters: `ec.spawn` is issued
      from inside another fiber, so the half-built `Fiber` lives only in a
      register or a frame on that fiber's stack while the world is stopped.
      The `Deque` buffer the earlier rounds chased is downstream of that.
      **RETRACTED — there was no other free path.** The first tagged CI catch
      (`31963103652`, `make ec-queue-audit`, aarch64) reported `flags 0x1` —
      `SWEPT` **clear**, i.e. freed by an explicit `Heap#free`, where every
      locally measured crash was `0x81` (the sweep). Its block is 384 bytes (16
      entries, the smallest capacity) against 1536/3072 locally, its holder's
      pointer sits at **block+24** rather than block+0, and it lands 3
      collections in rather than 16–200. So either the defect is reachable
      through two free paths or the two harnesses hit two different defects —
      and that was **the flag's own bug**: `SWEPT` was set only in
      `push_size_class_free`, and four freelist **rebuild** sites in
      `collect_sweep.cr` — which re-link already-free blocks after a chunk is
      emptied — reconstructed the header with a bare `FREE` and erased it.
      Measured: on a chunk-emptying workload the bit survives 278 of 278 with
      the fix and 0 of 278 without. Also checked, since the retracted reading
      rested on it — `Heap#free` and `realloc(size: 0)` fire **zero** times in a
      fiber-spawning workload, and Crystal calls `GC.free` only from the zlib
      and GMP hooks, so there was never a plausible caller. Now gated in
      `process_spec`, both directions, broken on purpose at `Expected: 278`.
      **Correction, and it retires the line above.** The grace now carries its
      saves into the next collection and asks whether they are marked there:
      across three runs **0, 0 and 1** were live, against **80–106 garbage**. So
      ~99% of what it saves is ordinary short-lived garbage (65–87 blocks of
      2 775 allocations, i.e. 2–3%), the saved `Fiber`s are **finished** fibers
      rather than fibers under construction, and "a `Fiber` mid-`initialize` is
      reachable from no root we scan" **is not supported**. The single live case
      does not restore it either — a block stored into a live object *after* a
      collection is legitimately garbage then and live now. What survives is the
      arm's effect (20/48 → 0/48, back-to-back, twice) and not its explanation:
      "the grace rescues live objects the mark missed" now has evidence against
      it, so the delay must be acting through *when a block returns to the
      freelist and is reissued*.
      **And it is a coverage gap, not a filter.** The grace now asks, with the
      world still stopped, where the value actually is: **not** on any fiber
      stack above the collector's entry SP (75 of 76), **not** in any suspended
      thread's captured GP registers (0 hits across 92 registers of 4 captured
      threads, 85 of 85), and `mark_root_candidate` **ACCEPTS** the address when
      handed it (88 of 88). So no root predicate rejects the value — not the
      type_id gate, not `base_only`, not alignment — it simply never arrives.
      That retires the whole class of fixes about loosening a heuristic.
      **Two corrections, both from this round.** (1) The locator's first version
      reported 87 of 87 hits "inside `scan_mutator`'s window, read and rejected";
      that was the search finding **its own parameter** on the stack, every hit
      at the same offset inside the collector's call chain. Excluding frames
      below `Heap#collect_entry_sp` removed all of them. (2) Late in the session
      the **committed** binary stopped reproducing at all — 0/8 at `ROUNDS=200`,
      0/12 under parallel load, minutes after 10/24, with no code change. The
      rate is host-state dependent, so the 20/48 → 0/48 comparison stands only
      because both arms ran back-to-back twice, and any new arm must wait for the
      repro to be live.
      **The collect-entry register snapshot came back negative too**: a `setjmp`
      taken at the public `collect` entry, before any collector frame can save
      the mutator's callee-saved registers, holds the address 0 times in 89
      reports. The address is nowhere — which is what garbage looks like, and is
      consistent with the correction above.
      **Unblocked, 2026-08-17: the repro was never dead — it needs
      `GCRY_THREAD_CENSUS=1`.** That knob reads `/proc` inside the pause and
      shifts the timing enough to bring the defect back: **0/20 crashes with the
      census off, 16/25 with it on**, on a 16-worker spawn workload. And the
      crashes are the **`Fiber` family** — 15 of 16 in `Fiber#makecontext`, none
      in `pthread_getattr_np`. So the family that could not be measured is now
      the one that reproduces fastest, in about ten minutes a batch.
      That reopened everything blocked on a live repro, and the size-class
      bisect ran. It eliminated more than it confirmed: the grace's effect is
      **not** the rooting (null-rooting is as effective), not the recording
      (recording without the walk does nothing), not a delay (a bare post-mark
      spin does nothing), not the `Fiber`-sized blocks (192-only is no better
      than control), and not merely locating the blocks (`find_block` alone does
      nothing). What remains is a single read: **`header.value.flags`** on each
      newborn ≥384-byte block, between mark and sweep, which takes ~10/18 to
      **0/18**.
      That pointed at the flags word rather than at reachability, and the first
      guess there is **out**: TLAB is off in this configuration
      (`tlab_enabled=false`), so its unordered `Flags::FREE` writes cannot be
      the writer.
      **And running both instruments together sharpens the real contradiction.**
      Ten crash reports: freed by the **sweep** 10/10, block 1536/768 bytes, and
      exactly one holder every time — the live `Deque`'s `@buffer`. Six audited
      crashes: **zero missed edges**. Both cannot be complete, and the gap is
      what the audit walks — **only marked parents**. If the `Deque` was itself
      unmarked at that collection its edge is never examined, so "the mark is
      complete" means *surviving objects have no dangling edges*, not *nothing
      dangling survives*.
      **Audited from the other side, and the answer is neither.**
      `GCRY_MARK_AUDIT_ALL=1` walks every used block as a parent, marked or not,
      and across five crashing runs reports **nothing**: when the buffer is
      freed, no pointer to it exists anywhere in the used heap. At fault time
      the holder search finds it on a **running fiber's stack** (17 hits, all
      `running`) under the `Deque` → `Fiber::StackPool` chain. So the buffer is
      allocated, held only in a register or stack slot, freed by a collection
      that cannot see it, and *then* stored into `@buffer` — the birth window,
      for the buffer.
      **But the suppressor is still not the rooting**: at n=24 interleaved,
      control 15/24, grace 0/24, and grace **rooting `null`** also 0/24. Two
      solid measurements that do not reconcile.
      **Registers eliminated too.** `GCRY_DYING_REGISTER_AUDIT=1` looks, before
      the sweep, for each about-to-die ≥384 block's address in every suspended
      thread's captured registers: **zero hits in five crashing runs**, with
      `dying_blocks_checked` 2–3 per run — small, but that is the entire
      population, and in a crashing run the fatal block is among them.
      So: not in the heap, not in suspended registers, and on a running fiber's
      stack immediately afterwards. The only region left is the **collecting
      thread's own frames** — which `scan_mutator` covers by design (it scans
      from below every collector frame up to the stack bottom) and which the
      holder search must exclude to avoid finding its own parameters.
      **And the mutator scan never offered it.** `scan_mutator_stack` now
      records the ≥384 block bases it hands to `mark_root_candidate`, and the
      dying audit fires in every crashing run: blocks of 384 / 768 / 1536 bytes
      — the `Deque` capacities — die *"not in the heap, not in a suspended
      thread's registers, and never offered by the mutator-stack scan"*.
      So at the moment it dies the buffer is invisible to **every root source
      gcry consults**: heap edges, suspended registers, the mutator scan, and
      the explicit root set (0 of 0 in every crash report). Immediately
      afterwards the address is in `@buffer` and on a running fiber's stack.
      **The region is named, and it is a stack that belongs to nobody.**
      `GCRY_ADDRESS_SPACE_AUDIT=1` (`src/gcry/address_space_audit.cr`) walks
      every readable mapping in `/proc/self/maps` at the moment of death and
      searches it for the dying block's address. Across fourteen runs the
      address is found on **in-flight fiber stacks** — mapped
      `STACK_SIZE - PAGE_SIZE` with a guard page below, owned by no `Fiber` and
      held in no pool — **61 times**, and on **pooled** stacks sitting in a
      `Fiber::StackPool` deque **24 times**. Both land 968–1408 bytes below the
      stack top, which is where `makecontext` writes a new fiber's first frame.
      gcry scans the stack of every fiber `Fiber.unsafe_each` yields; between
      `stack_pool.checkout` and the `Fiber` being published, and again after the
      fiber finishes, the stack is yielded by nothing and scanned by nothing.
      That is a **root source gcry has never had**, and it is the one the value
      crosses the collection in.
      Two instrument corrections make those numbers readable rather than
      flattering: the first version reported 47 hits that were the audit's *own
      frames* (it runs on the collecting fiber's stack and carries the target as
      an argument — now compared against `Roots.last_mutator_low/high`, the
      window the scan actually used), and it took a **SIGBUS** on a mapping
      `/proc/self/maps` calls readable, which killed the collection it was
      measuring — reads now go through `pread` on `/proc/self/mem`.
      **And rooting the in-flight stack closes it: 20/44 → 0/44.** Four arms,
      interleaved round-robin at n=24 with `GCRY_POISON_FREED=1` (what turns the
      defect into a fault) and `GCRY_THREAD_CENSUS=1` (what keeps the repro
      live): control **10/24**, pooled rooted **20/24**, pooled walked-not-rooted
      **13/24**, **in-flight rooted 0/24**, in-flight walked-not-rooted
      **14/24** — and a confirmation batch against control alone, **10/20 to
      0/20**. Each window got a twin arm that walks exactly the same memory and
      offers nothing, because the birth grace's zero turned out to be timing
      rather than rooting; here the twins separate cleanly, so the effect **is**
      the rooting, and only for the stack in flight. The pooled hits were stale
      copies.
      It is also not retention: same `heap_size`, same 160 collections, and
      *fewer* live objects than control (893 against 982). The arm adds roots
      that are live, not roots that are many.
      So the mechanism is named: `Fiber.new` checks a stack out of the pool,
      `makecontext` writes the new fiber's first frame onto it, and the `Fiber`
      is published only afterwards. In that window the stack belongs to no fiber,
      `Fiber.unsafe_each` does not yield it, and the pointers in that frame are
      unrooted — which is why the crash dies in `Fiber#initialize` →
      `makecontext`.
      **Correction, and the window has a different name: it is the stack of a
      fiber that is *ending*.** The arm above rooted every stack-shaped mapping
      no fiber and no pool claimed, and a coverage audit run beside it showed
      what that set actually was: **330 per run** were the stack Crystal parks on
      a `Thread` when a fiber terminates, against a handful genuinely in flight.
      The fix written from the in-flight reading — a hook on
      `Fiber::StackPool#checkout` recording exactly those — measured **13/24
      against 8/24**, which is nothing (p≈0.24), and was deleted rather than
      shipped on a maybe. Rooting the dying-fiber stack alone: control 11/24,
      **rooted 0/24**, walked-not-rooted 12/24; and the shipped code, rewritten
      and re-measured from scratch, **10/24 off against 0/24 on**.
      Crystal states the window itself: *"When a fiber terminates we can't
      release its stack until we swap context to another fiber."*
      `Thread#dying_fiber` parks it, so the owning `Fiber` is already out of the
      fiber list while the thread may still be **running on that stack** — and
      gcry's other-thread scan works from *pthread* bounds, which a thread on a
      fiber stack is nowhere near. Neither root source covers it.
      **Shipped**: read `Thread#@dead_fiber_stack` at root time and scan its top
      64 KiB. O(threads), no `/proc`, no size matching, portable; on by default
      (`GCRY_DEAD_STACK_ROOTS=0` disables), gated in `process_spec` in both
      directions, and not retention — same `heap_size`, same 160 collections,
      *fewer* live objects than control.
      **The pause cost does not show up.** `pause_budget --live-mb=20` over four
      runs an arm: p50 18.71–19.23 ms off against 18.91–19.92 ms on, p99
      26.4–35.5 against 22.4–33.9 — fully overlapping — and CI's `perf smoke`
      passed on the same commit.
      **Next**: the coverage audit still reports **4 mappings per run** it cannot
      account for. And the push carrying this fix produced a red aarch64 job with
      the **thread** family's crash — `make ec-queue-audit` in
      `pthread_getattr_np` on a poisoned `pthread_t`, a 192-byte block freed by
      an explicit free and reissued — which this fix does not touch and which
      did not reproduce on the re-run. The 5 h soak was dispatched against this
      commit; until it reports, "the fiber family is closed" rests on 0/24 in a
      two-second repro.
      `bench/log/linux/2026-08-17-address-space-audit/FINDINGS.md`,
      `bench/log/linux/2026-08-17-inflight-stack-roots/FINDINGS.md` (retracted),
      `bench/log/linux/2026-08-17-dead-fiber-stack-roots/FINDINGS.md`
      `bench/log/linux/2026-08-16-birth-grace/FINDINGS.md` Save only 192-byte blocks, then only the
      `Deque` buffer sizes (768 / 1536 / 3072), and see which subset still takes
      the crash to zero. Only the buffer sizes ⇒ the mechanism is reuse timing
      and the `Fiber` saves were volume; only 192 ⇒ the `Fiber` is back in the
      frame, on better evidence than it had.
      `bench/log/linux/2026-08-16-uaf-mark-complete/FINDINGS.md`,
      `bench/log/linux/2026-08-16-birth-grace/FINDINGS.md`
      Not a CI gate — it fails most runs on purpose; `make nested-spawn-uaf`.
      `bench/log/linux/2026-08-15-nested-spawn-uaf/FINDINGS.md`,
      `bench/log/linux/2026-08-16-uaf-holders/FINDINGS.md`
- [x] **The EC4 pause is the parked-fiber lag scan - priced, and declined
      (2026-09-14).**
      `bench/log/linux/2026-09-08-ec4-root-phase/`: 8.4 of a 9.2 ms p50 pause
      at Kemal `-c100` is `roots_fibers_ns`. Under multi-mutator STW every
      parked fiber is scanned 256 KiB below its saved SP (a fiber in transit
      may report a stale one); the pagemap low-water skip only helps on stacks
      no previous tenant faulted deeper, so pooled stacks lose it over time
      (~8 MB scanned per collection here; 15.5 ms with the skip off; 77 ms at
      lag 0). Fix belongs with the audit below: a fully parked fiber (wait
      queue, no owning thread) has a trustworthy SP and can be scanned from it
      as on EC1; only fibers in transit need the lag. A per-fiber high-water
      mark written at swap time would replace the pagemap probe.
      **The payoff is measured, and it is the deep case only (2026-09-13).**
      `fiber_lag_window_bytes` counts the nominal window — saved `stack_top` to
      scan start — and `low_water_skipped_bytes` what the pagemap probe removes
      from it. 256 fibers on a Parallel context, 10 collections: on stacks never
      faulted below the parked frames the window is 67 072 KiB per collection
      and the skip removes **all of it** (67 858 KiB; the probe can start above
      `stack_top`), so the proposal would save **nothing** there. With each fiber
      touching 512 KiB of stack and then parking shallow, the skip removes 2 470
      KiB and **64 602 KiB per collection is actually read — 246.6 KiB per parked
      fiber** — with `low_water_misses` at 2 560, exactly 256 fibers x 10
      collections. That second arm is the "pooled stacks lose it over time" case
      reproduced without a pool or any uptime: one deep call, then park shallow.
      **Two readings retracted on the way there**, both recorded because they
      were reported before being checked: the nominal window was taken for the
      reads (it is not — on untouched stacks nothing in it is read), and "266
      skips whether the run does 1 collection or 20" was taken for a skip that
      fires once per fiber (it is not — `@low_water_skips` is reset every
      collection, so the read reports the last one). `low_water_misses` and
      `low_water_unprobed` were added to settle it and are what make the third
      attempt evidence instead of a third guess.
      **The fix cannot be earned, and the arithmetic is now written down.**
      Its ceiling is a lag of ~0, which `bench/lag_width_ab.sh` measures
      directly at Kemal EC4: paired, arms alternating order, 8 trials, the
      narrow lag removes **0.970 ms [0.302, 1.638] of a ~6.4 ms pause p50**
      (7/8 trials) and moves throughput **not at all** (0.989 [0.775, 1.202]).
      The phase is what this item always said it was - `roots_fibers_ns` is
      80.6% of the pause with `GCRY_ROOT_PHASE_TIMING=1` - but 27.00 MiB of
      nominal window per collection is already down to 1.53 MiB by the time
      the pagemap skip is done with it, and the app reads 16.2 KiB per parked
      fiber where the synthetic deep arm reads 246.6.
      **And the predicate it needs is never available.** `fiber_lag_sp_known`
      counts the scans where the stop had an SP for every thread, which is
      what turns "no thread was found on this stack" into "no thread is on
      it": **0 of 2 620** on the deep arm and **0 of 34 989** on Kemal EC4.
      Structural, not luck - `stw_signal_exempt?` exempts SYSMON, so no SP is
      ever recorded for the EC Monitor, in the only configuration where the
      lag applies. Publishing the Monitor's SP at `MonitorGate.enter` reaches
      20 of 200 stops (measured); the rest needs the SYSMON signal exemption
      to end, which is an STW protocol change against a recorded history of
      resume races. ~1 ms of pause does not buy that.
      The per-fiber high-water mark this item proposed does not work either:
      a fiber's deepest-ever SP is *below* its current one, so a scan starting
      there is wider than the lag window, not narrower.
      `bench/log/linux/2026-09-13-fiber-lag-cost/FINDINGS.md`
      `bench/log/linux/2026-09-14-parked-fiber-lag-ceiling/FINDINGS.md`
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
      **And the one state where the list and reality differ is now measured and
      gated (2026-09-16).** Everything above covers the context *as the context
      lists it*. `Parallel#resize` does not mutate `@schedulers`, it replaces it
      — deliberately, so a concurrent `#steal` keeps reading a valid array — and
      on a shrink the overflow schedulers are dropped from it and told to shut
      down **cooperatively**: stdlib says they "won't stop until their current
      fiber tries to switch". So a `Scheduler` is run by a live thread while the
      context no longer lists it, and the pin block walks the new array.
      Measured with one non-yielding fiber per worker holding the window open,
      4 → 1: the shrink drops **24 named pins**, exactly
      `3 x (1 object + 7 ivars)` derived from `instance_vars` on both sides, and
      that quantity is what `bin/scheduler_roots --resize` gates on (red at 0
      with the pin loop removed). **Nothing is swept** — and the positive control
      says that is not because anything names it: delete
      `thread.@scheduler`'s pin and all three removed schedulers and their
      queues still survive, on the `Thread` body scan and the worker's own
      stack. That is the conservative coverage the pin block exists because it
      does not trust, in the one window where it is the only coverage. Latent,
      not live: nothing in this tree shrinks a context — `--workers` and
      `bench/kemal/src/server.cr` both resize once at startup, which only grows
      — so it is under a gate before a caller reaches it. Naming it would cost
      seven pins per thread per collection for a path nobody takes, so that is
      recorded rather than done.
      `bench/log/linux/2026-09-16-ec-shrink-window/FINDINGS.md`
      **Still open, and the reason this item stays unchecked:** none of this
      explains the 2026-08-10 soak SEGV. Nothing called `resize` then either, so
      the shrink window was never entered on that run. `Isolated` is opt-in and the soak uses
      plain `spawn`, so it cannot have hit that hole either. The soak sets no `GCRY_AUTO_LAYOUTS`, so
      those ivars were reached conservatively there anyway — what changed is that
      they no longer depend on it.
      `bench/log/linux/2026-08-15-ec-pin-completeness/FINDINGS.md`
- [x] **An 8 h soak on the overnight tree: PASS, and flat (2026-09-14).**
      28 743 collections, 28 646 010 allocations, 287 459 fibers, 2 870 315
      finalizable objects, **0 queue faults**. RSS 7 024 kB at start, 7 956 from
      hour 2 — every sample from hour 2 to hour 7 reads the same number — and
      7 800 after the drain, so the +932 kB is warm-up rather than a slope. The
      pause does not drift either: p50 1.80 ms in hour 0 against 1.76 ms in hour
      6, p99 between 2.73 and 2.95 ms throughout, and the one 9.47 ms p99
      maximum is in hour 0. Live objects hold at ~2 900 and collections at
      3 593/hour, so it is a steady state rather than a run that wound down.
      It does not speak for the EC4 pause item — that is Kemal `-c100` with many
      parked fibers, and this workload's p50 is 1.8 ms — nor for the
      chunk-release window found the same night, which needs the sweep's
      single-mutator path.
      `bench/log/linux/2026-09-13-soak-8h/FINDINGS.md`

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
      **And the other factor in the same product is now a knob too.** Chances =
      collections × occupancy; churn raised occupancy, and the collect cadence
      sat hardcoded at `sleep(1.seconds)`. `GCRY_THRESHOLD` does not move it —
      118/119/119 collections over 120 s at 32 MiB, 8 MiB, 2 MiB — because these
      collections are the harness's timer, not the allocator's. `--collect-hz=N`
      (default **1**) is the knob, and **two 5 h CI arms then priced it honestly**:
      three arms at 1 Hz against three at 20 Hz, identical otherwise, gave
      **×14.6 the collections but only ×2.56 the slot walks** (710 307 →
      1 818 412), because occupancy fell from **24.2% to 3.4%** — collecting 20×
      more often leaves 20× less time for fibers to pile into a queue, so the two
      factors are not independent and raising one eats the other. The 120 s local
      arms had projected ×16 with occupancy flat; a cadence knob has to be
      measured at the duration it runs at. Pause and RSS do improve (2.04 → 1.84
      ms p50, 30.4 → 10.8 MB max at 120 s); the workload cost at 5 h is −13% to
      −40%, not the −3.9% the short run showed. A `workflow_dispatch` input like
      the others.
      `bench/log/linux/2026-08-15-soak-collect-cadence/FINDINGS.md`
      **And a fault of the same family is now reproducible in seconds** — see the
      use-after-free item at the top of this section. It did not come from the
      soak: `make ec-queue-audit` crashed three times in a day and the poison
      said what it was. That is the answer this item was asking for, arrived by
      another route.
      **And the creation side had no lever, because the soak had one worker
      (2026-09-16).** Everything above raises the rate a bad slot is *seen*. The
      fault being hunted is a **cross-thread** run-queue corruption, and
      `bench/soak.cr` ran the whole workload on a single worker thread: Crystal's
      default context is `Parallel` but starts at capacity **1**
      (`init_default_context` calls `Parallel.default(1)`) and grows only if the
      program calls `Parallel#resize`, which this harness never did. Neither
      `CRYSTAL_WORKERS` nor `EC_PARALLELISM` moves it — measured, capacity 1 and
      2 OS threads on a plain `-Dgc_none` build *and* on
      `-Dpreview_mt -Dexecution_context` with `EC_PARALLELISM=4`, which is the
      configuration recorded as the **"EC4 + fiber churn"** arm on 2026-09-10.
      That arm was single-worker; its record is corrected in place. Kemal's EC4
      numbers and `soft_soak_ec4.sh` are unaffected — `server.cr` does call
      `resize`. `--workers=N` (default **1**, the baseline every earlier arm ran)
      is the lever, a `workflow_dispatch` input like the others, and the
      `config:` line now carries `ec_parallelism` read from the context rather
      than from the flag — a flag is a request, and that arm is what an
      unhonoured request looks like six weeks later. Priced at 90 s, churn 512:
      four workers keep occupancy where the cadence knob ate it (slots per
      collection 69.2 → 68.2, non-empty 90.9% → 97.6%) and produce the first
      `stw_waits` this workload has ever recorded (0 → 1), for −21% allocations
      and +13% RSS.
      `bench/log/linux/2026-09-16-soak-worker-count/FINDINGS.md`
      **Why the item stays open:** no soak fault has been reproduced. All of this
      raises the rate at which a run could catch one and shortens the report from
      "an hour later, in the consumer" to "the next collection"; whether that is
      enough is the next scheduled run's answer. Two 90 s arms are not a rate
      measurement, and what the 2026-08-10 run's own parallelism was is recorded
      nowhere — which is the argument for the `config:` line, not an answer.
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
- [x] **The arm64 `live_objects` drift was the collector working.** The
      regression above went red on `aarch64` and `darwin` and stayed green on
      `x86_64` — |drift| 1005 against ≤ 4 — which read like a counter defect on
      the two platforms that were not under CI when v0.14.0 fixed one. It was
      not. Reporting the drift signed, at two counts an order of magnitude
      apart, and against gcry's own heap walk settled it in one run: the drift
      was **negative** (−1007 / −1006), did **not** scale with the allocation
      count (−2 at 1 000), and the **walk agreed with the counter**. The cycle's
      collections were reclaiming ambient garbage that everything before it had
      left, in an amount that is a property of the spec suite and the platform,
      not of the heap. A pre-baseline collect removes it — x86_64 −110 → −8 — and
      the assertion now measures stranding, which is what the defect did and
      what a bound can honestly hold. The walk verdict is not kept:
      `Gcry::Invariant.enable` is global and checks after every malloc, so a
      spec that turns it on fires the documented off-by-one race from an
      arbitrary allocation site and kills the process. `GCRY_DEBUG_INVARIANTS=1`
      and the `make invariants` gate are where that check belongs.
- [ ] **A thread gcry has not heard of yet is neither stopped nor scanned.**
      Reached from the fifth aarch64 crash, which showed a `Thread`'s
      `@system_handle` read out of a **freed, poisoned block**. Two facts are
      measured: that poison, and that `GC.pthread_create` is a bare passthrough
      — no registration, no wrapper, no suppression. The rest is derived from
      Crystal 1.21.0: `start_thread` **discards** `checkout`'s return, so between
      `pthread_create` returning and `attach` running *on the new thread* the
      `Thread` object's only references are that thread's own frame and libc's
      argument slot. gcry learns about threads from `Thread.unsafe_each`, so
      until the thread pushes itself it is **not suspended** (it runs through the
      stopped world) and **not scanned**. Boehm does not have this window because
      `GC_pthread_create` registers the thread before user code runs.
      **Not reproduced**: 0 of 200 threads caught themselves freed, and the
      aggressive arms hang in a shape that resembles the known STW-startup hang,
      so they say nothing. Written down as a hypothesis with a measured symptom.
      **Measured, and the window is real.** `GCRY_THREAD_CENSUS=1` compares
      Crystal's list against `/proc/self/status:Threads` at every `stop_world`
      and has caught it: *"the OS reports 10 thread(s) and Crystal's list
      yielded 9, so 1 thread(s) are running through this stopped world,
      unscanned"*. Rate on a churn workload at 160 collections a run, six runs
      an arm: 0/6 at 4 workers, 1 sighting at 8, **2/6 at 16** — about one
      collection in a thousand, one thread, during worker startup. Counters on
      `/gc-stats` (`_checks` / `_gaps` / `_gap_max` / `_unanswered`, the last so
      "no gaps" cannot be "never looked"), gated in `process_spec`, broken on
      purpose and observed red.
      It does **not** yet show the window causes the crash: an unscanned thread
      only matters if something is reachable solely from it.
      **And the cheap fix does not work.** Holding Crystal's thread-list lock
      across `pthread_create` — `stop_world` takes the same lock, so a collection
      cannot begin during creation — was written and A/B'd at 16 workers, ten
      runs each: the gap rate did not move (3/10 either way) and it **introduced
      crashes in `stop_world`** (0/10 → 3/10). Reverted. It relocates the window
      rather than closing it: the new thread then blocks on that same mutex
      inside its own `start`, so when the creator releases there is still a
      thread that exists, is unlisted, and is racing the collector — now parked
      on a lock the suspend path does not expect it on.
      **The other half was built, and it splits into a right idea and a wrong
      implementation.** A trampoline in `GC.pthread_create` that records
      `pthread_self()` before user code, with `stop_world` dropping the record
      once the thread appears in Crystal's list: **the record is exactly right**
      — every census gap seen with it on reported `staged >= gap` ("gcry has
      staged 1 of them, so it knows they exist"), seven for seven, no overflows.
      **But it destabilises thread startup**: 8/10 runs crash against 0/10
      without it, on the same workload. Reverted, like the lock before it.
      A hang on the way is worth keeping: the staging table's class variables
      must be **eager**, because a lazily-initialised one is set up behind a
      guard and the first access happens on a pthread that has not finished
      starting — with an `Atomic` initializer the first thread hung, and the
      same trampoline minus the staging call ran clean.
      **The third attempt lands.** Recording from the **creating** side — stage
      the handle `pthread_create` just wrote, no trampoline, no new frame on the
      new thread — is **0/20 crashes against 0/20 without it**, and covers every
      census gap observed (`staged >= gap`, reported as "gcry has staged 1 of
      them, so it knows they exist"). An earlier 2/10 on this arm did not
      survive n=20. Gated in `process_spec`, both halves broken on purpose.
      It records only: what `stop_world` suspends and what the scan walks are
      unchanged, because two attempts that did change them broke the collector.
      Counters on `/gc-stats` (`thread_staged_now` / `_total` / `_overflows`,
      `thread_census_staged_covered`).
      **And the record is now acted on, behind `GCRY_STAGED_WAIT=1`.** Before
      stopping anything — and before `Thread.lock`, since a starting thread
      publishes by taking that very mutex — the collector waits, briefly and
      bounded, for a staged thread to appear in Crystal's list. Measured at 16
      workers: **crashes 6/60 → 0/60** (Fisher p ≈ 0.03) and **census gaps
      3/30 → 0/30**, at a cost of ~1.4% of collections waiting at all.
      The first version could not have worked and looked like it did: staging
      entries were released only by `stop_world`'s own walk, which runs after
      the wait, so **68 of 68 waits timed out** while the gap closed anyway on
      the delay alone. Draining published entries inside the loop fixed it —
      ~140 waits since, zero timeouts. A timeout now also drops the staged
      entries, so a thread that dies before publishing cannot buy a permanent
      per-collection spin.
      **Now on by default** (`GCRY_STAGED_WAIT=0` opts out) — the uncautious
      choice, made deliberately: the local repro is dead (`nested_spawn_uaf`
      0/23, `ec_queue_audit` 0/25), so CI is the only observer left and a knob
      nobody sets is never observed. Evidence for harm is nil, and the open
      question can only be answered where the defect appears — whether this also
      closes the **`Fiber` family** (`makecontext` poison on a
      `Deque(Fiber::Stack)` buffer), which has never been shown to share this
      window. **Worked** = the three gates go quiet over ~20 runs against a base
      rate of about one red in four. **Did not** = `ec-queue-audit` still dying
      on `Fiber#makecontext` while the `pthread_getattr_np` shape disappears,
      which would mean two windows and one closed.
      `bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`
- [ ] **An aarch64 SEGV in `pthread_getattr_np`, now seen twice.** Filed as a
      one-off after run `31933855152` (`make scheduler-roots`, commit `e7de946`,
      green on re-run); it recurred four hours later in run `31950823605`
      (`make ec-queue-audit`, commit `4645bf7`), same call chain, address ending
      in the same `800358`. That second landing matters beyond the count: it is
      in the *same target* as the known poison flake, so **"ec-queue-audit was
      red" is not a diagnosis** — two different defects fail that step and only
      the backtrace separates them. It is not the known STW-hang either: the stack-bounds snapshot is
      taken *before* the suspend signals, under `Thread.lock`, and this is a
      SIGSEGV inside libc rather than a wedge. What is left is
      `pthread_getattr_np` on a `pthread_t` whose thread has exited — the same
      family as `fix/stw-libc-under-suspension`, gcry asking libc about a thread
      whose lifetime it does not own. Two cheap counters would make the next
      occurrence say something (threads visited vs bounds read per snapshot; the
      `pthread_t` the loop is on when it faults). **Both are now built.**
      `stack_bounds_visited` / `stack_bounds_read` are on `/gc-stats` and gated
      in `process_spec` (Linux; Darwin reports zeros by design), broken on
      purpose and observed red at `visited=96, read=0`; and
      `stack_bounds_in_flight` carries the `pthread_t` being queried, which the
      SIGSEGV report now prints *before* the address line. **A third occurrence
      arrived on the first CI run after they landed** (`31961004141`), and they
      answered: the fault is 1048 bytes (`0x418`) into the thread descriptor the
      `pthread_t` points at, on the *next page* from the id itself, with 22
      threads visited and 21 read — so no accumulated coverage gap, just this
      call on this thread. A descriptor whose first page is mapped and whose
      next is not is what an exited thread looks like, which is the standing
      hypothesis, now with evidence. **A fourth arrived on 2026-08-17
      (`31995517368`) and repeats the third exactly**: same `0x418` offset into
      the descriptor, same `22/21` visited/read, i.e. the same query at the same
      point in the run. And the four cheap explanations are **eliminated from
      Crystal's source**: the handle is published before the thread joins the
      list, the main thread's is set before its push, removal precedes
      `system_close`, and `push`/`delete`/`Thread.lock` all take the same mutex.
      So the thread is in the list, alive, and carrying a handle its own code
      wrote. **Next**: record whether the faulting id had ever been queried
      *successfully* before — a repeat means it died between snapshots, a
      first-timer means it never worked. Not yet a release blocker — never seen
      outside CI — but it is the second-most-frequent red on the board.
      `bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md`
- [x] **The crash report died inside itself, silently — fixed 2026-09-13.**
      `make poison-holders` red three times in two days on the x86_64 runner,
      each time printing the holders header and nothing else, which read as a
      search that found nothing; green on a re-run of the same commit; never
      reproducible locally in 80+ runs including single- and two-CPU ones.
      Measured with `GCRY_SEGV_REPORT_STACK=1`: the alternate signal stack is
      **8 192 B with 3 472 already used** on entry, leaving 4 720 for a report
      that walks roots, heap and every fiber stack with a line buffer per frame
      and then repeats all three for the holder it found. Nothing said so
      because SIGSEGV is blocked inside its own handler — a synchronous fault
      there is a silent kill, not a second delivery — and because no state
      recorded which walk was running. Fixed with gcry's own **256 KiB**
      alternate stack, `SA_NODEFER`, and a one-byte stage stamp;
      `GCRY_POISON_HOLDERS_FAULT=1|2|3` is the positive control and is now a
      gate arm (each section names itself; without the fix all three die at
      `rc=139` naming nothing).
      `bench/log/linux/2026-09-13-report-stack/FINDINGS.md`
- [x] **A crash on Darwin cannot be told from a null dereference — closed
      2026-09-15.** The poison check that identifies a use-after-free reads
      the *faulting context's* registers. Linux reads glibc
      `ucontext_t.uc_mcontext.gregs` at the same offsets STW records.
      Darwin STW never does — it uses `thread_get_state` — and a SIGSEGV
      hands a `ucontext_t` whose `uc_mcontext` is a *pointer* to a
      `__darwin_mcontext64` that prefixes those GP words with the exception
      state. Until this, the reader was Linux-only, so a Darwin crash on a
      poisoned pointer arrived with `si_addr == 0` and read as a null
      dereference (2026-08-17 Darwin CI). Offsets transcribed from XNU
      (`uc_mcontext` at 48; GP words after the 16-byte exception state).
      Writer frames follow the same pointer, and Darwin records `__TEXT`
      plus the dyld slide so `exe+offset` is printable. `make segv-report`
      is the gate; the Darwin job runs it.
- [ ] **Close the Darwin CI asymmetry.** It is why the items above were open.
      `test-macos` runs `spec`, `process_spec`, the samples, `make
      chunk-search-race`, `make greg-roots`, `make scheduler-roots`, `make
      ivar-layout-roots`, `make ec-queue-audit`, `make perf-baseline`, both
      header-layout spec arms, the Darwin-only static-root and free-page
      probes, and — all added 2026-08-15 — **Debug invariants** (exactly what
      hid the item above for three releases), **`stw_mt_property_test`** and a
      **soak smoke**. Added 2026-09-15 with the two items above: **`make
      tls-roots`** and **`make segv-report`**, the gates for the main-thread
      TLS roots and the `__mcontext` crash reader. Neither had a Darwin arm,
      which is the whole reason both defects were Darwin-only.
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
      baseline recorded there — see the item below). **The Darwin soak smoke now
      gates.** It ran `continue-on-error` because its +4 MB RSS ceiling was
      measured on Linux and Darwin reclaims differently, and inventing a Darwin
      number would be the thing this board refuses. Four green runs on 2026-08-15
      measured it instead — **+2880 / +3136 / +2384 / +2640 kB** — and the Linux
      ceiling turned out to hold: worst +3136 against +4096 is 960 kB of
      headroom, 1.28× the 752 kB spread. Darwin does re-fault ~2.9× what Linux
      does, which is why it needed measuring and not assuming.
- [ ] **64 of 84 gates cannot be shown to fail without a hand edit.** Every gate
      asserts something; the question that has now bitten three times is whether
      it can still come out **red**. `make page-release-corruption` and
      `make live-graph-audit` had rotted into testing nothing and shipped that
      way for releases (both fixed in 0.26.0); the soak carried an arm recorded
      as "EC4" for six weeks while running one worker; the `--resize` arm added
      2026-09-16 passed on its first version because the window it measures was
      never open. In each the assertion ran and only its ability to fail was
      gone. Censused by `bench/gate_arm_census.py` so the number is re-derivable:
      **20** gates construct their red direction per run — the recipe requires a
      command to fail (`tls-roots`, `interior-only-buffer`,
      `unaligned-only-buffer`), or the harness forks a child under a breaking
      knob and judges it (`stw-watchdog` is the model: armed+stalled must print,
      armed+not-stalled must stay silent, stalled+unarmed must stay silent). For
      the other **64** it was established once by hand, and `ROADMAP.md` says so
      in prose **19** times — which nothing re-checks. Three were sampled by
      actually breaking the collector and all three went red
      (`each_thread_greg` stubbed → `greg-roots`; `has_inner_pointers?` dropped
      → `ivar-layout-roots`; the pin loop removed → `scheduler-roots --resize`),
      so this is about re-verification and not about hollow gates. The reusable
      finding from those breaks: **a survival assertion does not discriminate, a
      counter does** — in all three the object survived the break because
      conservative scanning reached it, and only a counter went red. The fix per
      gate is the `tls-roots` shape, a research knob restoring the pre-fix
      behaviour plus a recipe arm that requires it to fail; 64 of those is a
      program, not a change, and the order should follow what a rotted gate
      would cost rather than the alphabet.
      `bench/log/linux/2026-09-16-gate-arm-audit/FINDINGS.md`
      **First pass, and the knobs were already there.** `make knob-doc-check`
      enforces that every `GCRY_*` the collector reads is documented; nothing
      enforces that one is *used*. **Eleven** root-disabling knobs are read by
      `src/` and appear in no spec, no `bench/`, no recipe and no CI step — and
      `ROADMAP.md`'s claim that `GCRY_STACK_BOUNDS_NOGROW` is "gated in
      `process_spec`" is stale, it is not in `spec/` at all. Each knob was run
      against every fast root gate and the exit statuses tabulated, which bought
      two red arms for no collector code: `! GCRY_DISABLE_GREG_ROOTS=1` on
      `make greg-roots` (targeted — it reddens that gate and nothing else, and
      that gate covers the v0.19.0 shape where rot means silent sweeps) and
      `! GCRY_DISABLE_STATIC_ROOTS=1` on `make static-bss-roots`. Census 20 → 21.
      Not wired, with reasons: `GCRY_DISABLE_SP_CLAMP` **hangs** two gates rather
      than failing them (124 at a 90 s timeout), and `GCRY_DISABLE_STATIC_ROOTS`
      kills five of seven outright (exit 11). And **seven knobs no gate
      notices** — `DEAD_STACK_NOROOT`, `POOLED_STACK_NOROOT`,
      `MAPS_INFLIGHT_NOROOT`, `BIRTH_GRACE_NOROOT`, `STACK_BOUNDS_NOGROW`,
      `DISABLE_SCRUB_FIBERS`, `DISABLE_AUTO_LAYOUTS` — not because they are
      no-ops but because no gate constructs the condition they break. That is
      the part that needs harnesses rather than recipe lines.
      `bench/log/linux/2026-09-16-orphan-break-knobs/FINDINGS.md`
      **First of those conditions built: `make dead-stack-root`.** The v0.20.0
      dying-fiber stack root — `Thread#dead_fiber_stack`, credited with 11/24
      crashes → 0/24 on the nested-spawn repro — had **no gate at all**: its
      disable was in no spec, recipe or CI step, `dead_stacks_walked` was printed
      by `nested_spawn_uaf` and asserted nowhere, and that target is explicitly
      "not a gate" and absent from CI. So the fix could have regressed to a no-op
      in silence. Four arms, three of which require the victim to **die**:
      `--control` never plants the address, `--noroot` walks and offers nothing,
      `--disabled` turns the walk off and also asserts `walked == 0` so the knob
      is checked to still gate the walk rather than only the offer. On Linux,
      aarch64 and Darwin. Two corrections fell out of building it: the harness's
      first version allocated the victim *inside* the dying fiber, so its own
      frames held plaintext and the **control arm caught** the hold arm being
      unattributable; and `GCRY_DEAD_STACK_NOROOT=1` alone is not the twin —
      `offer = @dead_stack_roots`, so it walks *and* offers, which
      `docs/HARDENING.md` described as "same walk, roots nothing" and is fixed.
      Census 84 → 85, and its criteria were widened after they miscounted this
      very gate: **30 per run / 55 by hand**, against 20/64 reported hours
      earlier on the same tree.
      `bench/log/linux/2026-09-16-dead-stack-gate/FINDINGS.md`
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
      **The number is now recorded, and it is worth having for two metrics of
      four.** `bench/baseline/perf_smoke.json` carries five green `ubuntu-latest`
      runs from 2026-08-15 (`7709898`), taken from the `perf-smoke-report`
      artifacts that job already uploads, so no quiet host was needed:

      | metric | baseline | tolerance | gate fires at | fixed floor today |
      |---|---|---|---|---|
      | `pct_json` | 76.0 | ±9.375 | below **66.6** | 65 |
      | `rss_x` | 0.884 | ±0.0795 | above **0.964** | 1.25 |
      | `pause_p50_ms` | 0.7606 | ±0.2 | above **0.96** | 2.5 |
      | `pct_root` | 83.0 | ±12.525 | warn-only | — |

      So the throughput half of this item did not land: the runner's own spread
      (70.6–81.9 across the five) makes an honest `pct_json` tolerance so wide
      that the baseline gate sits **1.6 pp** below the fixed floor it was meant
      to tighten.
      **And the first real firing confirmed it was worse than that.** On
      2026-08-17 (`31997472378`) `perf-smoke` failed at `pct_json` **63.90** —
      under the fixed floor *and* outside the tolerance — on a commit whose only
      runtime change was a ≤64-entry array scan on the snapshot path, with RSS
      and pause both *better* than baseline. A re-run of the same job on the same
      commit passed.

      **2026-09-09: re-recorded on the bitmap default, and the two halves have
      swapped.** The 2026-08-15 file was taken on the freelist default; 0.24.0
      changed what the process allocates with, so it had been comparing the
      collector against a different one. Replayed against it, **5 of 10** green
      master runs from 2026-09-08/09 fail `--gate` — every one of them on
      `rss_x` (0.98–1.13 against a baseline of 0.884), none for a real
      regression. Anyone who had set `PERF_GATE_BASELINE=1` would have been
      blocking PRs on a policy change made deliberately in 0.24.0. The file now
      carries those ten runs (`bench/baseline/perf_smoke.json`, taken from the
      `perf-smoke-report` artifacts the job already uploads, so again no quiet
      host was needed):

      | metric | baseline | tolerance | gate fires at | fixed floor | self-fires |
      |---|---|---|---|---|---|
      | `pct_json` | 100.5 | ±11.7375 | below **88.8** | 65 | 0 of 10 (min 94.7) |
      | `rss_x` | 0.9585 | ±0.1425 | above **1.101** | 1.25 | **1 of 10** (1.132) |
      | `pause_p50_ms` | 0.6116 | ±0.4437 | above **1.055** | 2.5 | 0 of 10 (max 0.799) |
      | `pct_root` | 97.2 | ±6.9 | warn-only | — | — |

      `pct_json` is now the half that lands — the gate sits **23.8 pp above**
      the fixed floor, where the old one sat below it, because the default got
      faster (median 76.0 → 100.5) while the runner's spread stayed ~12 pp
      wide. `pause_p50_ms` still holds, 2.4× tighter than its floor. `rss_x` is
      the one that does not: the warm-chunk budget makes post-GC RSS the
      noisiest of the four, and one of the ten recording runs already sits
      outside its own tolerance, so `--gate` carries ~10% false alarms there.
      Next: `PERF_GATE_BASELINE=1` is worth turning on only once `rss_x` is
      either excluded from gating or given many more samples.

      **2026-09-10: the staleness is now self-detecting, because it happened
      again the next day.** #41 made the headerless layout the compile
      default, which invalidated the recording taken hours earlier on the
      header layout — the same mistake as the 0.24.0 allocator flip, one
      release apart, and both times the file kept comparing and kept reading
      as authority. `summary.json` now carries the `layout` the gcry arm was
      built with, the baseline carries the layout it was recorded on, and
      `perf_compare.py` prints `STALE:` and **refuses to gate** across a
      mismatch (or across a baseline with no layout at all, which is what
      predates the field). `--record` refuses to average two layouts into one
      number. Four new fixtures in `make perf-baseline` cover those paths.
      A human noticing that a default flip invalidated a baseline is not a
      control; this is.

      **2026-09-13: gating is ON, and the blocker was the rule rather than the
      sample size.** The tolerance was `max(half the observed range, 1.5 x IQR,
      floor)`, and both of those terms are proportional to the spread — so the
      gate sat a fixed number of standard deviations from the mean at every
      sample size. Simulated over normal samples: **2.28 sd at n=23, 2.29 at 40,
      2.51 at 100, 3.04 at 500, 3.24 at 1000**. The 23-run recording read
      2.12-2.62 sd, i.e. 2.7% false reds per run, and "record more green runs
      and then turn gating on" — the plan on this item for a year — needed about
      **1200 runs** against a 30-day artifact retention. It was a treadmill, not
      a lever.
      The tolerance is now stated in the unit the question is asked in:
      `TARGET_SD = 3.3`, floored per metric. On 24 green headerless runs the
      gates land at `pct_json` **86.06** (3.37 sd), `rss_x` **1.196** (3.57 sd)
      and `pause_p50_ms` **0.981 ms** (3.34 sd) — 0.10% combined per run, one
      false red per ~1000 runs, leave-one-out green on 24 of 24 — and every one
      of the three is **tighter than the fixed floor it was meant to tighten**
      (65, 1.25, 2.5). `PERF_GATE_BASELINE=1` is set in the perf-smoke job.
      What it cannot catch: a regression under 3.3 sd, about 14 pp of `/json`
      here. Narrowing the band trades the false-red rate back, so sensitivity
      needs *confirmation across runs* instead — two consecutive runs outside
      2 sd is 0.05% per pair and would catch ~9 pp at today's false-red rate,
      which needs state CI does not keep between runs. That is the next piece of
      this item. `bench/perf_gate_margin.py` is how the margin is measured, and
      `bench/log/linux/2026-09-13-perf-gate-flip/FINDINGS.md` is the record.

      **2026-09-13: recorded on the layout that ships, and the flip now has a
      number against it.** 23 green master runs since #41 (`e5bae04` through
      `9f99142`), from the artifacts the job already uploads. Ten was the plan
      and ten was wrong: the first ten read the `pct_json` spread as 96.6-105.2,
      the thirteen after them ranged 93.9-108.4, so a ten-run recording would
      have put the gate 0.94 pp from a false alarm on a run that had already
      happened.

      | metric | baseline | tolerance | gate fires | fixed floor | self-fires |
      |---|---|---|---|---|---|
      | `pct_json` | 99.7 | ±9.9 | below **89.8** | 65 | 0 of 23 (min 93.9) |
      | `rss_x` | 0.947 | ±0.1115 | above **1.058** | 1.25 | 0 of 23 (max 0.993) |
      | `pause_p50_ms` | 0.6399 | ±0.2 | above **0.8399** | 2.5 | 0 of 23 (max 0.7503) |
      | `pct_root` | 99.5 | ±9.95 | warn-only | — | — |

      `rss_x` no longer self-fires — the condition this item set for turning
      `PERF_GATE_BASELINE=1` on — because headerless post-GC RSS is both lower
      and tighter (0.77-0.993 against the header layout's 0.98-1.13).
      Leave-one-out passes 23 of 23. **And the flip still does not land**, for a
      reason that is now arithmetic rather than judgement: the gates sit 2.16 to
      2.50 sd from the mean, i.e. 0.62% / 1.07% / 1.55% per run, and any of the
      three fails the run — **3.2% combined, one false red every ~31 runs** on a
      branch that takes several pushes a day. Widening the tolerance is not the
      answer either: at ±9.9 the `pct_json` gate already sits 24.8 pp *above*
      the 65% floor it was meant to tighten. What earns the flip is ~3.3 sd per
      metric (one red per ~650 runs), which more samples buy for free since the
      tolerance is `max(half-range, 1.5x IQR, floor)`.
      Recording the first non-stale baseline the repo has had also exposed a
      latent defect in the comparator's report: `baseline: none recorded yet`
      was the fall-through of the staleness chain, so it printed under every
      non-stale comparison — and every baseline that ever shipped here was
      stale, so no green path had reached it. The first fresh baseline printed
      its provenance and then denied it existed. Fixed, with the fixture for the
      converse in `make perf-baseline`.
      `bench/log/linux/2026-09-13-perf-baseline-headerless/FINDINGS.md`

- [x] **The process heap's counters lose updates — both halves of the trade
      measured 2026-09-13, and the default stays plain.**
      The cost first: the reason the atomic path is off is a LOCK RMW on the
      allocation hot path, and measured on `bench/micro/alloc_ns.cr` with
      alternating pinned arms it is **not resolvable** — atomic/plain 0.9836
      [0.9573, 1.0098] on one thread over 40 M allocations, 1.0091 [0.9877,
      1.0304] on four over 20 M. Both CIs span 1.0. A Kemal `/json` A/B
      (`bench/counters_ab.sh`, 12 paired trials, warm-up discarded) is ±10% on
      this host and cannot see a few percent at all, which is worth recording:
      end-to-end RPS is the wrong instrument for an allocation-path question.
      Then the loss: `GCRY_INVARIANT_COUNTER_LOSS=1` states the `live_objects`
      invariant even of a heap that may lose updates — the measurement the
      scope correction retired — and counts instead of raising, with the
      checker's double read still skipping a counter that *moves* between the
      two reads. **4.6 million forced comparisons, zero losses**: 3 277 952 with
      atomic counters and 3 278 005 with plain in the original sighting's shape
      (main plus the monitor, nothing else), and 660 649 more with eight
      spawned allocators. An increment dropped on purpose through
      `debug_drift_live_objects` is caught at every walk after it, which is what
      makes those zeros a measurement rather than a blind spot — and the first
      attempt at this harness measured almost nothing and said so: two spawned
      threads made `concurrent_mutators?` skip 406 300 walks against 1 636
      comparisons.
      So the plain counter stays, the atomic path stays an escape, and the
      measurement is a gate: `make counter-loss`, three arms, in CI. Not
      claimed: that the loss is impossible. It happened 3 times in 40 runs on
      the v0.20.0 tree, and the allocation path has been rewritten twice since
      (bitmap allocator, headerless layout); the likeliest reading is that one
      of those removed the race. The gate is what will notice if it returns.
      `bench/log/linux/2026-09-13-heap-counters/FINDINGS.md`

- [x] **The original statement of that item, kept for provenance.** `note_alloc_bytes` uses plain
      `set(get + 1)` unless `heap_counters_atomic` is set, and `heap.cr` calls
      that safe on the grounds of "single mutator + rare SYSMON". Measured
      against: with the invariant checker on, `spec/invariant_spec.cr` reports
      the process heap's `live_objects` **permanently one below** the walk in
      **3 runs of 40**, in a program whose only threads are main and the
      monitor. A lost increment is not a sampling race — it never comes back.
      `total_bytes` and `bytes_since_gc` are incremented the same way, and a
      `bytes_since_gc` that drifts low delays collections by exactly the bytes
      it forgot.
      This surfaced as a flaky test and was fixed as a *scope* correction: the
      invariant is now stated only of a heap that keeps its counter
      (`Heap#counters_may_lose_updates?`), which took the flake from 6/25 to
      **0/60**. That makes the checker honest; it does not make the counter
      right.
      **Next**: decide the trade deliberately rather than by default. Turning
      the atomic path on unconditionally costs a LOCK RMW on the allocation hot
      path — the reason it is off — so it needs the Kemal throughput numbers
      beside it. The cheaper alternative is to make SYSMON's allocations not
      count, if they can be identified.

- [x] **The guarded sighting is attributed, and it is a live block in a released
      chunk — fixed 2026-09-14.** The 2026-09-13 sighting could not be read
      because the report consulted the release ledger only inside the heap span.
      With that hoisted, the next one (CI `34787711949`, one of the 18 overnight
      runs) said it outright: `in a chunk gcry RELEASED — base 0x7f6e5cea0000,
      131072 bytes, empty size-class chunk release, at collection 206 [...]
      **Blocks still allocated at release: 1**`, with `Collections since: 0`.
      That number is a popcount of the occupancy bitmap at release, so it is not
      a stale pointer into legitimately freed memory — it is a live block inside
      memory the collector gave back.
      **The window, from the code:** the sweep unlinks an empty chunk from
      `@chunks` inside the stop and queues it, its `@chunk_index` entry survives
      until the post-STW flush's `index_remove`, the allocator resolves pooled
      chunk addresses through that index, and `bitmap_pool_candidate?` accepts a
      chunk whose blocks are all free — which a queued chunk's are. The flush
      runs after `start_world`, so a mutator can take a block out of a chunk
      already queued for unmapping.
      **Fixed by refusing:** the flush re-reads occupancy immediately before
      releasing and keeps an occupied chunk mapped, putting it back on the live
      list. Refusing cannot lose — a chunk kept costs RSS, a chunk unmapped
      under a live block costs the object — and `refuse_live_release` did not
      cover it (it asks about other *indexed chunks* inside the range, and under
      `GCRY_UNMAP_GUARD=1` it is not even reached).
      **Not reproduced locally, and the counters say why:** 0 refusals in 24
      churn children with the flush held 20 ms, on 8 cores and pinned to 2. With
      several mutators alive the sweep queues nothing at all (0 chunks considered
      in 120 collections) and single-threaded it queues plenty (37 in 30) but has
      no second mutator to take a block. The window needs both, which is the
      thread-birth shape a 2-vCPU runner hits about once in 24 children. The
      test is the next CI sighting: it should print the refusal instead of a
      fault.
      **And the kept chunk is now named, because refusing made it anonymous
      (2026-09-14).** A chunk put back on the live list is an ordinary chunk:
      if it is released for real later and a stale pointer faults on it, every
      line of the report describes that ordinary release and nothing says the
      chunk had been through this window. A sixteen-slot ledger records base,
      length, collection and occupancy at each refusal, and the report reads it
      in both branches a fault can land in — in-span with no live block, and
      out of span, since releasing a chunk is what moves an address out of the
      span. The window still does not open here, so the ledger has a positive
      control rather than a promise: `GCRY_REFUSE_EMPTY_RELEASE=<n>` refuses
      the first n empty-chunk releases whatever the occupancy says, and `make
      kept-release-report` faults into such a chunk and requires both lines.
      The report tells the control from a sighting by the count it recorded —
      0 means the knob forced it, non-zero means a mutator took a block through
      the index entry the chunk still had. `make thread-churn-uaf` gains a
      `reported` arm with the report and no other knob, which is what the CI
      sighting in the *default* arm had no way to answer from.
      `bench/log/linux/2026-09-14-occupied-release/FINDINGS.md`

- [x] **The crash report smashed its own stack printing a line — fixed
      2026-09-14.** `RawOut.append` stops at `LIMIT` (480 B) and takes a bare
      pointer, so it cannot see where the caller's array ends: a buffer below
      `LIMIT` is not a truncated line, it is a write into the frame around it.
      The kept-release line above is 377 bytes and its buffer was 256. The 121
      bytes past the end took `occ` first — the line then read "a mutator took
      one" two clauses after printing "0 block(s) allocated", which is the
      first thing that looked wrong — and the return address next, so the
      report exited at 0x0 **inside itself, with the description of the fault
      it had been called for still unflushed**. `gdb` put the second fault in
      `report_kept_release`'s own `flush` with two frames of message text on
      the stack above it, which is the shape.
      **Thirty-two other buffers were under the limit**, two already able to
      run past their end on the widest line: `collect_scan.cr`'s index/list
      disagreement is 417 bytes with every number at full width against a
      352-byte buffer, and 349 on an ordinary mapped chunk — three bytes of
      margin. All thirty-three are `UInt8[RawOut::LIMIT]` now, and `make
      raw-buf-check` fails the build on a buffer smaller than the writer that
      fills it, for the two hand-rolled writers that predate `RawOut` as well
      (`EcQueueAudit` 300/320, `StwWatchdog` 250/256, both already sound).
      **The gate that found it passed while it was happening**, because it
      asked only for the line: it now also fails on a report that faults inside
      itself, on a kept-release line with no fault description after it, and on
      a block count that contradicts the knob that produced it — observed red
      on all three with the 256-byte buffer restored.

- [x] **A large object is released under load on the fat app — FIXED
      2026-09-13.** The title said *live* from 2026-08-23 to
      2026-09-12; the holders search, run at the release instead of at the
      fault (`GCRY_RELEASE_HOLDERS=1`), says otherwise. At the instant the
      chunk is let go: explicit roots **0**, one word in a 32-byte `type_id 0`
      block that **nothing** points at, and **0 of 11** stack words above
      `@collect_entry_sp` — every one of them inside the collection's own
      frames rather than a live mutator frame. Both objects were garbage and
      the release was correct. The fault-time answer could never have said so:
      it arrives 109 collections later, and "holders: none" at that distance
      is about a different heap. So what remains is a write through a pointer
      the collector cannot see, and two of the three places that can hide one
      closed on 2026-09-12 — registers are spilled and scanned for every
      suspended thread and for the Monitor, and thread-local storage became a
      root. Dead stack and non-gcry memory are what is left, and the next
      instrument is a backtrace of the *writer*, not of the reader.
      `bench/log/linux/2026-09-12-release-holders/FINDINGS.md`
      **And the writer is now named (2026-09-12).** The report never said who
      wrote, because the only backtrace available was Crystal's — which
      allocates DWARF tables, needs `Fiber.current`, and whose allocation
      *became* the block the report was about. A signal-safe walk from the
      faulting `ucontext` replaced it, and on its first run named a
      three-week-old fault: `mark_ref_slot` ← `scan_thread_roots` ←
      `run_collection_body`. **The writer was the collector**, in its own
      execution-context root pin. And "SIGSEGV at 0x0" was never an address:
      the register held `0xdead7fb15cbe0848`, a tagged poison word whose top
      bits make the access non-canonical, which Linux reports as a fault at 0.
      `mark_ref_slot` now refuses such a slot address, counts it and names the
      pin site (`collect_scan.cr:174`, the `Fiber::ExecutionContext` block) and
      the freed block. The rate does not move — the guard stops gcry faulting
      on the damage, and the damage is upstream — and the fault relocates to
      Crystal's `Monitor#transfer_schedulers_blocked_on_syscall` reading the
      same poison. So a live EC-family object is being freed, both the
      collector and the Monitor read it, and the Monitor is the one thread the
      stop never suspends: its registers are covered only when it parks in
      `MonitorGate.enter` (238 of 240 collections) and its stack is scanned
      with no recorded SP. That is the next thing to read.
      `bench/log/linux/2026-09-12-writer-frames/FINDINGS.md`
      **THE FIX (2026-09-13): read the mutator count once.** In the
      post-STW section the sweep asks `multi_mutator_threads?` about the world,
      and it asks six times between the stop and the end of the sweep:
      `sweep_after_world?` inside the stop, where the decision it drives is
      taken, and `relink_chunks_after_world?` plus
      `munmap_empty_chunks_this_collect?` again *during* the sweep, of a number
      this workload changes eight times a round by design. Fixed on both axes —
      `latch_sweep_mutator_count` pins it for the whole collection, and the
      relink decision is read once per sweep rather than at each of its three
      sites. **Measured on `make thread-churn-uaf`, five runs, both layouts:
      guarded 7 of 24 and poisoned 17 of 24 with `GCRY_SWEEP_MUTATOR_LATCH=0`,
      0 of 24 on every arm with it.** That harness is now the regression gate
      instead of a reproducer, both layouts, each with a `--control` arm that
      must still fault.
      **And a claim retracted.** This item said on 2026-09-12 that the
      mechanism was a chunk dropped with no rebuild to take it off `@chunks`,
      pointing its `next` into the unmap queue. Not supported: two assertions
      written for exactly that — `any_drop && !store`, and "linked into `kept`
      and never published" — never fired in either arm. Chunks in
      `@chunk_index` and not on `@chunks` go from 5 of 14 runs to 1 of 14 with
      the fix, reduced and not eliminated, while the crash goes to zero — so
      the divergence is correlated through the same trigger and is not the
      crash's mechanism.
      **Where the divergence comes from (2026-09-13).** Sampling the off-list
      count after each step of the post-STW section — the sweep and nine
      flushes — it grows at **the sweep and nowhere else**, cumulatively, in
      runs whose every sweep reports `store=1, drop=0`. That leaves the
      prepend race: the walk reads `@chunks` and follows `next` while
      `map_chunk` prepends under a lock the walk does not hold, so a chunk
      mapped during the walk is invisible to it and publishing `kept` over the
      head drops it from the list while `index_insert` keeps it in the index.
      **Splicing that prefix back in at the publish was written and withdrawn
      for the second time**: the shipped residual stays at 1 of 14 runs and the
      pre-fix shape goes from 5 of 14 to 14 of 14, because the walk rewrites
      `next` in place and the prefix is not separable from the chain being
      rebuilt. Any real fix has to stop the rebuild mutating in place — build
      the chain aside and publish once — rather than work around it; taking
      the list lock across the walk is the 0.21.1 hang. The residual is one
      chunk on a workload that maps thousands, at the sweep step, and the crash
      it was thought to explain is at zero across five gate runs on both
      layouts.
      **The consequence closed, and the cause decomposed (2026-09-13).**
      `clear_all_marks` walked the `@chunks` list while the marker reaches
      chunks through `chunk_containing`, i.e. the index — so a chunk the index
      knows about and the list does not kept its marks, its blocks read marked
      forever, `mark_impl` returned early on them and nothing followed their
      edges. The clear now walks the index (the measured superset: listed and
      not indexed is 0 in every run). It was expected to close a latent hazard
      — mark residue is 0 of 20 runs with the old walk — and instead it turned
      the gate's control arm green, which decomposed the defect: over 12
      attempts, shipped **0**, the mutator-count trigger alone **2**, the
      list-based clear alone **0**, both **7**. The trigger produces off-list
      chunks; the clear is what makes them fatal; either alone is nearly
      harmless. So the mechanism *was* stale marks in off-list chunks — the
      model two assertions could not confirm from the sweep, because the sweep
      is only half of it. `--control` now sets both knobs. What remains of the
      divergence is a leaked chunk 1 run in 14, an RSS question rather than a
      soundness one — and the clear now has a gate of its own,
      `make mark-clear-index`: the shipped walk leaves no indexed chunk holding
      a mark (0 of 20 runs) and the control, which needs both halves of the
      pre-fix shape, leaves some (11 of 14). Its control runs in child
      processes because that shape crashes as readily as it leaves residue, and
      both outcomes prove it. `chunk_index_only_bytes` gives the retained cost:
      2.7-3.3 MB over a few hundred collections in the pre-fix shape.
      **AND THE RESIDUAL IS SIZED (2026-09-13): it rides mappings, not
      uptime.** A stranded chunk is never swept and can never rejoin the list —
      the rebuild walks from `@chunks` — so every byte in it is retained for the
      life of the process. But the strand needs a *prepend*, and a prepend
      happens in `map_chunk`: no mapping, no event, so a heap that has reached
      its working size stops losing chunks. That axis took two wrong readings
      first. Per collection: the pre-fix arm climbed 8 → 28 → 49 → 55 → 57
      chunks with its heap tracking it 4.26 → 8.85 MB, and the plateau at
      buckets 3000/4000 was the tell. Per uptime: three children × 30 000
      collections stranded nothing, heap flat at 3.477 MB — which read as a
      bound until `chunks_mapped` showed those runs mapped **32 chunks in 1200
      collections**. "Nothing in 90 000 collections" was nothing in forty
      mappings.
      Measured against mappings, with a workload whose live set grows and drops
      so chunks are released and mapped again: **shipped strands 0 of 12.1
      million mappings** — 699 171 in the first pass, then 11 389 909 more in two
      overnight children of 200 000 collections each, both ending at the heap
      size they started with. The 95% bound is 2.6 per ten million mappings, i.e.
      **under 0.04 bytes retained per chunk mapped**. The earlier figure, kept
      because it is what the first pass could say: 0 of 699 171 mappings (532 716 + 160 175 in steady state, 6 280 across 200 short
      processes), a 95% bound of 4.3 per million, i.e. under 0.6 bytes retained
      per chunk mapped. The one shipped sighting does not survive as a rate
      either: the identical command, 60 more runs, strands nothing — one event
      in 74 runs.
      **And the pre-fix arm is the real finding.** With the mutator count read
      per decision again, a workload that maps strands **80-181 per 1000
      mappings** and ends with **97-99.3% of the heap in chunks no sweep will
      ever visit** — 1 GiB in 1368 collections where the shipped tree sits at
      15 MB. So the latch fix closed a near-total heap leak that needed nothing
      rarer than allocation plus threads, not only the rare use-after-free it
      was landed for — and that is the likeliest explanation of the fat app's
      RSS this item has carried as a separate mystery since 2026-08-23.
      So the rebuild stays as it is: restructuring it buys at most 0.6 bytes
      per mapping against a hang history in that exact code. The instrument
      ships instead — `make chunk-list-drift`, three arms in ~35 s, capped at 5
      stranded per 1000 mappings (not zero: the race is open and a gate on zero
      would red CI on the real event; three orders of magnitude under the
      pre-fix rate, so reopening it fails).
      `bench/log/linux/2026-09-13-chunk-list-drift/FINDINGS.md`
      **ROOT CAUSE (2026-09-12): the chunk index and the chunk list are not
      the same set.** `chunk_containing` reads `@chunk_index`; every *walk*
      reads the `@chunks` list. Measured with `GCRY_CHUNK_LIST_AUDIT=1`, which
      excludes the pending-unmap chain because a dropped chunk is off the list
      and still indexed by design: **1 chunk indexed but not listed in about 6
      of 14 runs** under thread churn, **0** the other way, none at all on a
      quiescent program. (The first version of the audit counted the pending
      chunks too and reported 2–27; that number is corrected here.) The
      chain from there is mechanical and every link is measured or read from
      the source: `clear_all_marks` zeroes mark bitmaps through the list, so an
      off-list chunk's marks are never cleared → every block in it reads
      permanently marked → `mark_impl_unlocked` returns early on an
      already-marked block → the object is never pushed onto the mark stack →
      `scan_object` never follows its edges → the `@schedulers` buffer it
      points at, whose own chunk *is* listed, is swept and poisoned → the next
      collection's pin walk reads the poisoned element as `sched` and
      `pointerof(sched.@name)` is a non-canonical address the kernel reports as
      a fault at 0. The same divergence also means those chunks are never
      swept, which is a leak and is why nothing noticed. The fix is the
      invariant, not the symptom: the two structures must describe the same
      set, or the walks that carry correctness must read the authority
      `chunk_containing` reads. Which producer diverges is still open, and it is
      none of the three that looked like it: `map_chunk` links the list before
      indexing, under one lock; `unlink_chunk` removes from both under that
      lock; and splicing the sweep's rebuild so a concurrent prepend survives
      moved nothing (**5 of 14 runs diverging before, 6 of 14 after**, and the
      rebuild does not even run on this harness, which is multi-mutator). The
      audit is what will tell a fix from a coincidence.
      **And it names a structure (2026-09-12).** The pin sites now carry a
      compile-time tag, because `__LINE__` cannot discriminate nine callers
      that are one `{% if %}`'s macro expansion. The refused slot is
      `sched.@name`, from `ec.@schedulers.each`, with `sched` itself read as
      poison — and only one block's payload carries its own tag, so the word
      holding `sched` was inside the freed block. **The freed 16-byte block is
      the `@schedulers` array's two-slot buffer**, freed while the
      `ExecutionContext` and the `Array` that owns it are both live and both
      pinned by the walk reading them. First data structure this defect has
      ever named. What is still open is why that buffer is unreachable: the
      `Array` is pinned and a heap edge to an interior pointer is allowed on
      purpose, so one of those is not true when the buffer is freed.
      Original sighting:
      2026-08-23 while cutting gcry vs Boehm on acikturkiye: the gcry binary
      dies under `wrk` in about one run in eight, in a request fiber writing
      JSON. `GCRY_UNMAP_GUARD=1` — added for this, and what made it legible —
      releases a chunk with `mprotect(PROT_NONE)` instead of `munmap` and keeps
      its identity, so the report names it. Two sightings agree: a **69 632-byte
      large-object chunk**, released by the **large-object path**, with the write
      28 672 and 34 343 bytes into it. That is the JSON response buffer after it
      outgrows the 32 KiB size classes. A live object was collected.
      **Ruled out**: the empty-chunk release (`GCRY_KEEP_CHUNKS=1` still died),
      unmarked allocation during a collection (`alloc_large` marks on both paths
      — read), a `noscan` layout field dropping its target (`mark_noscan` marks
      it), `MADV_DONTNEED` (cannot fault), and interior pointers
      (`GCRY_INTERIOR=1`: 1 of 16 against a guarded baseline of 3 of 16).
      **The fork is decided**: `GCRY_MARK_AUDIT=1` reported **0 edges** in the
      run that crashed, so no heap object holds the buffer when it dies. The
      only holder is a stack slot or a register, and the root scan is not seeing
      it. First place to look is `GC.realloc` growth — between `realloc`
      returning a new large block and the caller storing it, the only reference
      is a register.
      **Worth stating**: a smaller buffer would be a size-class block, freed and
      reused rather than unmapped, so the same defect would corrupt silently
      instead of faulting.
      **A locking asymmetry was found, fixed, and then proven on its own terms.**
      `take_large_free` walks `@large_freelists` holding `@alloc_lock` while
      `trim_large_cache` walked it holding nothing and unmapped as it went; a
      second step in the same function, `update_heap_bounds_after_unmap`,
      rewrote `@heap_min` / `@heap_max` outside the lock as well. Since the
      application had stopped reproducing, the question was asked directly:
      `make large-cache-race` puts four workers on 40 KiB allocate-write-verify-
      free while a peer trims, and it is **5 of 5 faults with
      `GCRY_TRIM_UNLOCKED=1`, 0 of 5 serialised**. Whether it is **also this
      crash** remains unproven: 0 of 24 with the fix against 1 of 24 with the faithful
      control, and then 0 against 0 at two concurrencies with the arms
      interleaved. The rate fell from 7 of 60 to nothing for a reason that is
      not the knob, so **step one next time is re-establishing the baseline on
      the current tree**; until the crash reproduces at a resolvable rate, no
      arm here means anything.
      `bench/log/linux/2026-08-23-acik-crash/FINDINGS.md`
      **The baseline is re-established, and it needs no application
      (2026-09-12).** `make thread-churn-uaf`: eight short-lived threads per
      round, one collection per round, 240 rounds — about a second per
      attempt. It fires on **both** layouts with nothing set, 14 of 942
      headerless and 16 of 924 on block headers (~1.5%), and an earlier
      reading of "0 of 40" on the same workload was underpowered rather than
      clean. `GCRY_POISON_HOLDERS=1` raises that an order of magnitude by
      turning a stale read into a fault, and
      `GCRY_THREAD_UNSTAGE_ON_DEATH=1` raises it again by removing the
      pre-stop staged wait's accidental delay — 15 of 18 with both.
      The sighting is this defect's shape at a different size: a 212 992-byte
      chunk released by the **large-object release** path, the write **48
      bytes** into it every time, no heap holder, and the range present on a
      *running* fiber's stack. `GCRY_TRACE_LARGE=1` ties it to its
      allocation: mapped at collection 94, released at 96, written 109
      collections later. Sizes vary across sightings (45 056, 57 344,
      212 992), so a growing buffer rather than one structure, and the first
      user word at release is a pointer into the binary's own mapping — a
      buffer of pointers to static data, not a `Reference`.
      **One ambiguity to resolve before trusting any arm**: a failing run has
      usually raised something first, and Crystal's backtrace printer then
      allocates hundreds of kilobytes of DWARF tables, so the released block
      may be the *printer's* buffer and therefore a second symptom rather
      than the cause. A sighting with no prior exception is what would settle
      it, and the harness does not isolate one yet. The standing first
      suspect is unchanged: `GC.realloc` growth, where the only reference
      between the call returning and the caller storing it is a register.
      `bench/log/linux/2026-09-12-thread-churn-large-uaf/FINDINGS.md`
      **The bisect, and it retires this item's own hypothesis
      (2026-09-12).** With a one-second reproducer the knob matrix becomes a
      bisect. 36 attempts per configuration, baseline 25 of 36:
      `GCRY_SOUND=1` **25/36**, `GCRY_STACK_LOW_WATER=0` 18/24,
      `GCRY_FULL_SUSPENDED_STACK=1` 20/24, `GCRY_STW_STACK_LAG=0` 21/24,
      `GCRY_KEEP_CHUNKS=1` 17/24, `GCRY_CHUNK_RADIX=0` 16/24, `GCRY_TLAB=0`
      14/24, `GCRY_PARALLEL_MARK=0` 20/24 — and then two zeros:
      **`GCRY_BITMAP_ALLOC=0` 0/36** and **`GCRY_DISABLE_LAZY_SWEEP=1`
      0/36**.
      **It is not a missed stack or register root.** Maximal conservatism
      changes nothing, and neither does removing the low-water skip, the SP
      clamp or the parked-fiber lag. This item reasoned from
      `GCRY_MARK_AUDIT=1` reporting 0 edges that the only holder must be a
      stack slot or a register the scan is not seeing — but 0 edges is
      exactly what a stack-rooted buffer looks like, so that never followed.
      `GC.realloc` growth is no longer the first suspect.
      **It is the post-STW sweep, in the bitmap allocator.**
      `sweep_after_world?` restarts the world and *then* rebuilds `@chunks`
      and unmaps empty chunks on the stated assumption that it is the sole
      mutator, with peers held off by `@block_other_heap` when they touch the
      heap. Both release paths do it — the large-object release and the empty
      size-class chunk release — and the sighting is the **first** line of a
      failing child's stderr, so it is the primary event and not the
      backtrace printer's buffer. `GCRY_DISABLE_LAZY_SWEEP=1` removes the
      section and the defect with it: a one-variable mitigation for anyone
      hitting this, and a default worth revisiting once the pause cost of
      dropping it is measured.
      **Three fixes attempted and withdrawn, with numbers**, so they are not
      re-spent: holding the large in-flight root past the handover (29/48 —
      the clearing comment's reasoning is still wrong, but it is not this
      defect); refusing the sole-mutator sweep when gcry knows of unlisted
      live threads (the count is *always* zero — the churned threads are
      created **during** the post-STW section, after the decision was
      correctly made); and holding `pthread_create` for that section, which
      is the only place the window can be closed from (35/48, and it
      deadlocks).
      **A fourth, also withdrawn with numbers (2026-09-12).** The remaining
      unscanned place a reference could live was thread-local storage — the
      third branch of the holders sentence, never tested. It turned out to be
      a real defect (the main thread's TLS was not a root, fixed, see below)
      and **not this one**: `GCRY_TLS_ROOTS` moves the committed harness's
      poisoned arm 15 of 18 against 14 of 18, i.e. not at all. A first
      version that took the whole 824 KiB containing mapping did appear to
      halve the rate, and that was conservative retention of an extra 100k
      words rather than a root being found — worth stating, because shipping
      it would have read as a fix.
      `bench/log/linux/2026-09-12-tls-not-a-root/FINDINGS.md`
      **A fifth, and it was the obvious one (2026-09-12).** The sweep's
      occupancy publish is a whole-word `occ[i] = mark[i]` — a
      read-modify-write of a word the allocator writes with a lock-free atomic
      OR, so between reading `mark[i]` and storing it a mutator's freshly
      published block should be erased, which is one live block per race and a
      chunk that then reads empty enough to release. It is not happening.
      `GCRY_SWEEP_OCC_AUDIT=1` asks, per dead word, whether a cursor slot is
      mid-allocation inside a block the pass just called dead: **0** over
      283 259 words published with mutators live and 482 380 kept blocks
      checked, and **0** over the 183 360 words per run of this item's own
      reproducer — on the runs that faulted. Three things close the window and
      none is local to the loop: cursor sets are settled inside the stop
      (pinned if frozen mid-allocation, else retired and forced back through
      the class lock), allocate-black marks every block handed out while
      `@collecting`, and `@collecting` stays true through the whole post-STW
      section. An atomic publish plus a mark-before-occupancy reordering was
      written, measured against a knob that held each dead word open for
      200 µs, found to fix nothing measurable, and reverted. The store's own
      comment argued only that a *per-bit* clear would be worse, which is a
      different claim, and has been corrected to the real one.
      **`sweep_cursor_pinned` reads 240 per reproducer run**, so much of that
      section's work is skipped rather than done; what a skipped chunk's
      `live_objects` accounting does is the next thing to read.
      `bench/log/linux/2026-09-12-sweep-occ-publish/FINDINGS.md`

## Next — the thread family, then Darwin performance parity

- [ ] **The second use-after-free: gcry reads a `Thread`'s `@system_handle` out
      of a freed block.** It faults inside `pthread_getattr_np` under
      `stop_world`, on a `pthread_t` that is gcry's own tagged poison
      (`0xdeadff…`). Seen on aarch64 CI on 2026-08-16 (twice), on x86_64 in the
      STW × TLAB test on 2026-08-17, and again on aarch64 on 2026-08-17 **with
      the v0.20.0 fix in place** — so the dying-fiber stack root does not touch
      it. The block is 192 bytes. **What the last report said about *how* it was
      freed does not stand**: "an explicit free rather than the sweep, since
      reissued" was decoded from `si_addr`, which was the poison **plus
      `0x418`** and named a block five along — the same reporter bug that
      produced a false "explicit free" from cleared flags, retracted in the
      FINDINGS the day it was printed. Who freed it is still open.
      **The obstacle is the observer, not the analysis.** It does not reproduce
      locally: `ec_queue_audit` 0/20 and 0/25 in two batches, `nested_spawn_uaf`
      never produces this shape, and the 5 h × 3 soak on 2026-08-17 did not fire
      it either. Every sighting so far is CI, mostly aarch64.
      **The instrument is built and wired.** `GCRY_THREAD_BLOCK_AUDIT=1`
      (`src/gcry/thread_block_audit.cr`) asks the fiber family's question about
      one type: after the mark and before the sweep it reads Crystal's `type_id`
      out of every used block, names each block of the watched type the mark did
      not reach, and hands its address to the address-space walk, which names the
      region that holds it. The general audit could not see this defect and the
      reason was size twice over — its trigger walks only the ≥384 B band and a
      `Thread` is 192 B, and it fires for whichever block died first, never this
      one. It rides on `scheduler-roots`, `ec-queue-audit` and the x86_64
      `stw_mt_property_test` step, i.e. on all three gates that have caught the
      defect, at +3% on the property test and no measurable cost on the others.
      `GCRY_DYING_TYPE_ID=<n>` retargets it, which is what `make
      thread-block-audit` uses to require it to name a death it plants and to
      stay silent when the same objects are held — without that, a quiet CI arm
      would say nothing.
      **And it caught it, on the first batch: 4 of 10 aarch64 reruns.** All four
      in `ec-queue-audit`, all at collection 2, all saying the same thing — the
      dying 192-byte `Thread`'s address sits **six times in one 16 MiB anonymous
      mapping that gcry can name as nothing**: no heap block, no fiber stack, no
      pooled stack, no thread stack, at **byte-identical offsets below that
      mapping's top in all four runs** (`0x1850 0x1800 0x1768 0x1760 0x1758
      0x0A40`). A region mapped whole and used from the high end, with a frame
      layout that repeats exactly, is a stack; the classifier had **4–5** thread
      bounds against ~100 live fibers, and one of the four crashes lands in
      `ThreadPool#attach` ← `Thread#start` ← `thread_proc`, on the new thread's
      own start path. In one of them the poison the crash faults on is the
      tagged form of **the same block the audit named one collection earlier**,
      which is the first time this defect's death and its crash have been the
      same block in the same run.
      **And the next catch decided it — it is the birth window, and the
      pre-stop wait giving up is what opens it.** Two more catches the same day,
      on two runs of the same commit, both with the precondition and the death
      in the **same collection**: `the wait for a staged thread GAVE UP — the
      world stopped with it unpublished. 5 listed, 5 bounded, 2 staged`, then a
      192-byte `type_id 173` block dying, off Crystal's list, held only in the
      16 MiB stack-shaped mapping — and, in the same report, `5 on Crystal's
      list … the kernel says 6`. One thread outside the stopped world, its
      `Thread` object covered by no root, swept; the thread then publishes and
      the next `stop_world` reads `@system_handle` out of the freed block. Both
      crashes fault on the poison of exactly the block the audit named.
      Baseline for contrast: 40 precondition sightings across 20 green runs,
      **every one caught by the wait**, never a timeout.
      **Still an inference**: that the dying object is that thread's. The
      handle comparison is only consistent with it — glibc recycles `pthread_t`
      values, measured in this repo's own runs (one id across eight collections
      while the staged total went 4 → 11).
      **And the fix needs none of the three options that were on the table** —
      not an unbounded wait, not scanning a staged thread's stack, not deferring
      the collection. The object is already in gcry's hands: Crystal calls
      `GC.pthread_create(…, arg: self.as(Void*))`, so the `Thread` *is* the
      argument the hook is handed. `src/gcry/thread_birth_root.cr` roots it
      there and releases it in `stop_world`'s existing walk once the thread is
      on the list. One `add_root` per thread created, and nothing about the
      stopped world changes — which is the point, because two earlier attempts
      at this defect changed collector behaviour and broke it.
      **Gated, and the window is now reproducible on demand.** A real `Thread`
      publishes in microseconds, so `make thread-birth-root` holds the window
      open with a **raw** pthread created through the same hook, which never
      joins Crystal's list: rooted the block survives, and with the twin
      (`GCRY_THREAD_BIRTH_NOROOT=1`, same records, roots nothing) or the knob off
      it **dies** — the defect, local and deterministic for the first time.
      **Left open and counted**: a thread that never publishes keeps its root for
      the life of the process, and the interval *inside* `pthread_create` is
      still uncovered (a trampoline on the new thread was tried for the staging
      record and crashed 8 runs in 10).
      **And one of those "left open" lines was hiding a hole, now closed.** The
      64-slot table was sized against concurrent births; slots are freed by
      `release`, which runs inside `stop_world`, so what it actually holds is
      births **since the last collection** — 65 `Thread.new`s with none in
      between overflow it, 200 overflow it 137 times, and an overflowing birth
      used to be rooted by nothing at all. It is now rooted and never released:
      a leaked `Thread` instead of an uncovered one. `make thread-birth-root`
      gained `--burst` / `--burst-unrooted`, which is the second local
      deterministic repro of this window and the first that needs no timing.
      `Platform`'s staging table has the same shape and overflows on the same
      input; there it costs the pre-stop wait rather than the root, and
      `thread_staged_overflows` counts it.
      **The crash-rate measurement**: 9 completed reruns of the aarch64 job with
      the fix in, all green, 0 dying-`Thread` reports (a tenth was cancelled and
      is not counted). Stated with its weight and not more: a batch *before* the
      fix was also 0/10, the rate is bursty on this fleet, and Fisher against
      the 3/10 control is p ≈ 0.2. The evidence that does not depend on the rate
      is the local gate, where the window is held open on purpose and the block
      dies without the root and survives with it, 20 of 20.
      **Next**: leave the sampler running and revisit the rate once more pushes
      have accumulated; the item stays open until CI has enough runs to say so.
      **What the stop epoch (2026-09-12, item below) changes here**: nothing
      about the window itself — an unpublished thread is still neither
      suspended nor scanned — but it supplies the mechanism a fix needs. A
      thread can now be signalled more than once without the duplicate
      suspending it with nobody waiting, and whether a delivery is honoured is
      decided by the handler against the stop id rather than by the collector
      getting a call site right. **The first half of that is now done
      (2026-09-12).** The acknowledgement has moved off `Thread#@suspended`
      into the `pthread_t`-keyed slot table, which the collector reserves for
      every thread before it signals anyone, so the handler calls nothing
      Crystal owns. That was not only a prerequisite — it closed a defect of
      its own, below. What is still missing to suspend a *staged* thread: its
      stack bounds have to come from the creating side
      (`pthread_getattr_np` on the new handle once `pthread_create` returns)
      and it has to be given a slot and signalled like any other. Separate
      change, separate red arms — the two earlier attempts at this family
      broke the collector by doing it in one step.
      **A live defect found on the way, and fixed:** Crystal's `Thread#start`
      pushes itself onto the list **before** it sets its TLS, so `stop_world`
      could signal a thread with no `Thread.current` — and Crystal's accessor
      *creates one on a miss*, allocating a `Fiber` and a `Thread` and pushing
      it onto `Thread.threads` from inside a signal handler with the world
      stopping. It then set `@suspended` on that **second** object, never the
      one the collector was watching, so the stop spun forever for a thread
      that had in fact suspended itself. That is `phase=suspend`, one thread
      unacknowledged, handle live, handler entries incremented — the aarch64
      shape, though whether it is *the* aarch64 hang is unknown and
      `stw_suspend_no_tls` is the counter that will say. Driven
      deterministically by `make stw-ack-window` against a raw pthread:
      shipped `acked=true listed_delta=0`, restored path `acked=false
      listed_delta=1`.
      `bench/log/linux/2026-09-12-stw-ack-birth-window/FINDINGS.md`
      **The birth window is narrower than this item has assumed, and the
      *death* window is the real one (2026-09-12).** `Thread#start`'s first
      statement is the push, and before it the new thread allocates nothing
      and holds exactly one GC reference — itself, which `ThreadBirthRoot`
      roots; once it has pushed, a stop in progress holds `Thread.lock`, so
      it cannot run through the stopped world either. The mirror is
      uncovered: `Thread.threads.delete(self)` runs *before*
      `Fiber.inactive` and `detach { system_close }`, so a dying thread
      spends its last instructions off Crystal's list — neither suspended
      nor scanned — still dereferencing itself.
      **It was masked by an accident**: `wait_for_staged_threads` spins 2 000
      times before giving up, on every stop, and those spins sat between a
      thread detaching and the world stopping around it. Dropping a dead
      thread's staging record — obviously right, and the thing that takes
      that wait's timeout rate from 398-of-400 to nil — removes the mask and
      crashes: **7 of 40** runs of 960 short-lived threads, against 0 of 40
      before, and 0 of 40 for a pure delay in the same place, so the trigger
      is the missing wait rather than the timing. `GCRY_POISON_HOLDERS=1`
      names a use-after-free on a 16-byte block that no holder search
      accounts for; rooting every `Thread` for its whole life does not fix
      it, so the victim is not the `Thread`. Kept as
      `GCRY_THREAD_UNSTAGE_ON_DEATH=1`, off by default and documented as a
      reproducer: this family has not had one that fires in seconds since
      2026-08-16.
      **And an unbounded leak, fixed on the way**: a birth root was released
      only when the pre-suspend walk found its thread on Crystal's list, so a
      thread that published and exited between two collections kept its root
      for the life of the process — `outstanding` **3 197 of 3 203** births,
      each pinning a `Thread`, its closure and its main `Fiber`. The root now
      ends at the thread's death, observed through the `pthread_detach` /
      `pthread_join` hooks with one collection of grace, or at once when
      glibc hands the handle to a new thread. 960 short-lived threads:
      `outstanding` 4, `overflows` 0, against 961 and 705 with the old policy
      restored (`GCRY_THREAD_BIRTH_DEATHS=0`).
      `bench/log/linux/2026-09-12-thread-life-root/FINDINGS.md`
      **The obvious cover was built and withdrawn, and the reason is worth
      more than the code was.** With the acknowledgement off `Thread` objects
      and the birth root naming every thread gcry has seen created and not
      seen end, the invisible set is computable — armed handles minus
      Crystal's list — so suspend and scan them like anything else. Both
      halves are unsafe for the same missing fact: **there is no safe way to
      ask whether a `pthread_t` still names a thread.** Guarding with
      `pthread_kill(id, 0)` segfaults on the first collection, 3 of 3,
      because a slot can outlive its thread by the grace collection and the
      probe then dereferences a freed `struct pthread` — the `+0x418` shape,
      reached from the other direction, which also makes the abandonment
      path's use of that probe worth revisiting. Trusting gcry's own death
      marks instead removes the crash and hangs 1 run in 3, when a thread
      dies between the mark being read and the signal being sent. The set
      was also empty in the workload that crashes (`unlisted_seen=0` over
      120 collections), so it cost two fatal modes and covered nothing.
      Where a next attempt should start: the dying thread is the only party
      that can speak for its own handle, and `GC.pthread_detach` already
      runs **on** it — it can publish its own bounds and park cooperatively
      the way the Monitor does, with no stale-handle question anywhere. That
      covers `detach` to exit, not `Thread.threads.delete` to `detach`.
      **Name the victim first.** It is 16 bytes and it is not the `Thread`;
      two of the three attempts here were aimed at objects that turned out
      not to be it.
      **Corrected attribution (2026-09-12, later the same day).** The
      reproducer does not crash in the dying thread. Bare — no poison — it
      raises rather than faults, and the stack names a thread being **born**:
      `Thread#start` → `Fiber.new` → `Fiber#initialize` →
      `Thread::LinkedList(Fiber)#push` → `Thread::Mutex#unlock` returning
      **EINVAL**, i.e. `Fiber.fibers`' mutex is not a valid mutex. EINVAL and
      not EPERM, so it is not a non-owner unlock — the memory is wrong. A
      second sighting lands in the Monitor's `every` rescue with the same
      error and a different consumer, then SEGVs inside DWARF decoding while
      printing, which turns the evidence into a backtrace storm. Under
      `GCRY_POISON_FREED=1` the same defect appears as the 16-byte read
      instead, and poison perturbs the timing enough that that arm fires
      almost never (0 in 534) — so the bare arm is the one to drive. Sizes
      measured and ruled out for the 16-byte block: `Thread` 184,
      `Thread::Mutex` 48, `Fiber` 176, `Fiber::StackPool` 24,
      `EC::ThreadPool` 48, `Thread::LinkedList` 32, `Fiber::Stack` 24 — so it
      carries no `type_id` and the dying-type audit cannot name it.
      **And a soundness hole closed on the way**: every thread the stop
      suspends by signal has its GP registers scanned, because a reference
      can live only in a register — and the Monitor is never signalled, so it
      was the one thread whose registers nothing captured. It parks in
      `MonitorGate.enter` on **238 of 240** collections, so the hole is on a
      hot path. It now spills them with the same `setjmp` pair the collector
      uses on itself, into a local its own stack scan already covers. This
      did **not** change the reproducer's rate (56 of 258 against 49 of 252):
      it closes a hole, not this crash, and a survival A/B cannot
      discriminate for the reason `make greg-roots --explain` gives.
      **And a shape to keep in view**: the stop now prints
      `SUSPEND ABANDONED … pthread_kill(0) says ESRCH` when a thread on
      Crystal's list has a handle libc says names nothing. That is this
      defect's signature seen from the other side, and it is now a line in the
      log rather than a twenty-minute timeout.
      **Caveats kept in the open**: the walk is `TRUNCATED` at 512 MiB in every
      catch, and there is no no-arm control batch yet, so 4/10 is not a rate to
      quote.
      `bench/log/linux/2026-08-20-dying-thread-holder/FINDINGS.md`
      `bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md`,
      `bench/log/linux/2026-08-17-dead-fiber-stack-roots/FINDINGS.md`

- [ ] **The aarch64 job hangs in `ec-queue-audit`, about one run in seven, and
      it has been reading as `cancelled`.** Six of the last forty runs of `test
      (aarch64 native)` ended at the 20-minute job timeout — 2026-08-20 (three)
      and 2026-08-22 — and every one checked was killed with `Terminate orphan
      process: … (ec_queue_audit)`. A job timeout is reported as *cancelled*
      rather than failed, so this has never been read as a defect, on the runner
      where the `Thread` use-after-free lives and in one of the two gates that
      has caught it.
      **The phase is now known.** The first run with the instrumentation in
      (2026-08-22, run `32575506486`) failed at 7m46s instead of being cancelled
      at 20 minutes and said `STOP-THE-WORLD STALLED 10009 ms in phase=suspend`
      — so it is `stop_world` spinning in `until thread.@suspended.get` for a
      mutator that never acknowledged its signal, not the harness's fiber waits
      and not a slow runner. The spin now records which thread it is waiting on
      and how many have acknowledged, so the next sighting names the victim;
      `GCRY_STW_TEST_SUSPEND_STALL_MS` and `make stw-watchdog`'s `armed+suspend`
      arm are what make that report provable rather than hoped for.
      What is still open: why that thread does not acknowledge. Candidates worth
      separating are a lost signal, a thread caught mid-start or mid-exit, and a
      handler that cannot run — the id and the `n of m` count are what will tell
      them apart. The wait now also asks `pthread_kill(id, 0)` after about a
      second and prints whether the handle names a live thread, which is the one
      question that separates "the signal was lost" from "the handle came out of
      a freed `Thread`" — the open use-after-free is on this same runner.
      **And five retention specs at once on aarch64 (2026-09-13, run
      `34770477564`).** `test (aarch64 native)` failed `dormant_revive_spec`,
      `empty_chunk_grace_spec`, a heap-shrink assertion, `dormant_chunk_bytes`
      and `Invariant.live_object_checks` — 5 of 274 — on a **documentation-only
      commit** whose tree had passed the same job one run earlier, and a re-run
      of the same job passed. Five retention specs failing together on one host
      and on no other is host variance, not a collector change; the candidate
      worth checking when it recurs is the runner's page size, since every one
      of them reasons about chunk residency. Recorded because nothing else
      would remember it.
      **The tally after a night of 32 runs (2026-09-14).** `test (aarch64
      native)` was the only job to go red on a tree that could not have caused
      it, and it did so four times: the same five chunk-residency specs three
      times (runs `34770477564`, `34772210050`, `34795331109`) and
      `make stw-epoch` once (`34801276385`, "a redundant suspend signal after
      the resume hung the collector even with the epoch on"). Every one passed
      on a re-run of the same commit. Locally: 0 of 80 for the specs, 0 of 6 for
      the epoch gate. That is ~12% of aarch64 runs failing for host reasons,
      which is high enough to hide a real regression behind a re-run habit — and
      the five specs now fail with their state attached, including both page
      sizes, so the next one carries evidence instead of asking for another run.
      **A Darwin sighting of the same gate, different shape (2026-09-13, run
      `34769097853`).** `test (darwin native)` failed in `ec-queue-audit` with
      the audit refusing to name two planted values — `faults: 0 -> 0 (poison
      0x7f1700000149, outside the heap)` and a live non-Fiber object where it
      wanted a `Runnables` — while the *structure* check did name the second
      one. Not a hang, and not attributable to the commit: the Darwin job runs
      neither of the gates that commit touched, the five master runs before it
      were green, and re-running the same job on the same commit passed. Kept as
      a sighting rather than a diagnosis, which is what a Darwin sighting was
      worth until the `__mcontext` reader landed (2026-09-15) — the item two
      above.
      **The retry now exists, and the epoch is what made it safe (2026-09-12).**
      The symmetry with `start_world`'s resume retry had been refused twice for
      a good reason: a redundant `SIG_RESUME` runs an empty handler, while a
      redundant `SIG_SUSPEND` stays pending inside the handler and is delivered
      *after* the thread resumes, suspending it again with nobody waiting.
      `Gcry::Platform`'s stop epoch closes that — 0 when no stop is in
      progress, the stop's id while one is, stamped per thread in the
      `pthread_t`-keyed slot table — so the handler serves a delivery only
      once per stop and declines every duplicate. `stop_world` then resends
      every `GCRY_STW_RESEND_SPINS` up to `GCRY_STW_RESEND_LIMIT`, and past
      the limit asks `pthread_kill(id, 0)`: on `ESRCH` it reports
      `SUSPEND ABANDONED` and stops without a thread that no longer exists,
      rather than spinning out the job timeout. `make stw-epoch` has six arms,
      three red on purpose — no resend hangs on a dropped signal, no epoch
      hangs on the duplicate, and a live thread that answers nothing hangs
      either way. That last one is the honest limit: **this repairs a lost
      delivery, not a thread that cannot run its handler.** Which of the two
      the aarch64 runs were is what the enriched `SUSPEND STALLED` line now
      answers — it carries resends unanswered, handler entries, and declines
      split stale/redundant, so flat handler entries mean the signal never
      arrived and climbing declines mean it did.
      Two latent defects fell out of building it, both in that slot table and
      both a **missed root** before they were a hang: the claim's
      `compare_and_set` result was never checked (it returns a tuple, always
      truthy, so every thread in a stop claimed the same slot), and
      `clear_thread_sps` left the ids in place, so a peer could match a slot
      another thread had just claimed. Two threads on one slot means one
      thread's stack is scanned from the other's SP and registers.
      `bench/log/linux/2026-09-12-stw-stop-epoch/FINDINGS.md`
      Three levels of instrumentation, for the record: the harness's own waits give up after 30 s and
      print how many fibers arrived, how many are still parked on the context's
      global queue and what the audit had counted (`--stall` is the positive
      control for that); every gate in that step is bounded with `timeout 300`
      so it fails with its output rather than being cancelled; and the step arms
      the STW watchdog so a stopped world that never restarts names its phase.
      Whether the hang is inside `stop_world` at all is the first thing the next
      sighting will settle. Not reproduced locally: 60 runs of the audit-on arm
      on x86_64 Linux, 0 hangs.

- [x] **A mutator could read the chunk index with no lock, and now cannot —
      closed 2026-08-22.** `chunk_containing` skips `@index_lock` while
      `@world_stopped` is set, on the documented grounds that only the collector
      can be there; `start_world` cleared that flag after resuming every thread,
      so between the two every mutator took the unlocked path against a peer's
      `index_insert` / `index_remove`. `GCRY_INDEX_AUDIT=1` counts it: 173 326
      foreign unlocked reads across 15 runs before, 0 after, gated both ways by
      `make stw-index-race`. **Bearing on the item below**: the sighting there
      faults in `find_block` under `tlab_alloc_small`, a mutator index lookup,
      on the one arm where mutators make 11.5 M such lookups a run — so the
      mechanism fits and is closed, but nothing here reproduces that crash and
      only its absence from CI will say whether this was it.

- [x] **`find_block` from a mutator handed back `@chunk_index[-1]` — closed
      2026-08-22.** The last-chunk cache tested `@last_chunk_idx` and then read
      it again to index with; a concurrent `invalidate_chunk_cache` between the
      two loads made the second read index one slot *before* the array, which is
      libc's malloc header — hence the same constant `0x91` every time, handed
      to `ChunkHeader.large?`. One writer was unsynchronised too: a second
      `invalidate_chunk_cache` outside `@index_lock` on the chunk-mapping path.
      Read once, bounds-checked, and the chunk verified to contain the address;
      the unsynchronised invalidation deleted. `live` and `realloc` 5 of 8 → **0
      of 8**, `alloc` and `idle` 0 either way, and `index_cache_torn` shows the
      race was firing **6 709** times in a three-run arm rather than rarely.
      Gated both ways by `make find-block-race` on x86_64 and aarch64.
      Two readings retired by measurement on the way: a reallocated array
      (`moved=0`, and an immortal index changed nothing) and an unwritten slot
      (zero-filling changed nothing).

- [ ] **A mutator frozen while holding `@index_lock` would wedge the sweep —
      and the precondition does not occur on this tree (measured 2026-09-13).**
      `index_insert` and `index_remove` now count their sections and whether the
      world was stopped: **1 155 sections alone and 586 with a second mutator
      holding the lock, 0 of them inside the stop.** The sweep's placement is
      `sweep_after_world?`, so the collector's index surgery runs with mutators
      running, and there is no section a frozen holder can block. What a holder
      costs instead is a *bounded* stall: a 30 s hold makes the harness kill its
      child at 12 s, a **1.5 s hold finishes** — the collector is waiting on a
      lock whose owner is still running, which resolves when the owner lets go.
      And if that ever changes, the report will say so: the watchdog could only
      say `phase=sweep`, which names no lock, and those two sections now leave a
      breadcrumb so it names the lock and the chunk. `make index-lock-wedge`
      fails if a section runs inside the stop without the watchdog naming it —
      the silent-hang shape. Still open, because this is a property of the
      current sweep placement rather than a proof, and the original note is
      kept below.
      `bench/log/linux/2026-09-13-index-lock-wedge/FINDINGS.md`
      **The shape, as first written:**
      `chunk_containing` holds that spinlock for the length of a lookup, and a
      suspend signal arrives wherever it likes; the sweep's own `index_insert` /
      `index_remove` take the same lock unconditionally, so a thread frozen
      holding it leaves the collector spinning with the world stopped. Observed
      only as far as "a thread suspended inside `SpinLock#lock`" under gdb,
      which is the harmless half — frozen *acquiring* it costs nothing.
      **Not the aarch64 hang**, and that is settled rather than assumed: that
      hang names `phase=suspend`, which is before `@world_stopped` is set and
      before any sweep runs. Left open because the fix is not small — the
      collector cannot simply take the unlocked path, since a mutator frozen
      mid-`index_insert` leaves the array itself half-updated — and because
      nothing has yet been seen to hit it.

- [ ] **An unattributed crash in the TLAB+nursery arm, twice, on two
      platforms — very likely the one closed above, pending its absence.**
      The mechanism now fits without any gap: the crash faults in `find_block`
      under `tlab_alloc_small`, TLAB is what puts `find_block` on the allocation
      fast path, and that is the one arm where mutators make millions of chunk
      lookups a run. What is missing is the only thing that could make it
      certain — the CI crash was never reproduced, so this closes when it stops
      happening and not before. Separate from the `Thread` family above and
      still not shown to be related to it. `stw_mt_property_test --tlab --nursery` died on **x86_64**
      on 2026-08-17 (run `32002309556`, master) leaving a bare `Segmentation
      fault` with no backtrace and no gcry output, and on **Darwin** on
      2026-08-22 (run `32564282704`) with a Crystal backtrace and nothing else:
      `Heap#find_block` ← `tlab_alloc_small` ← `allocate` ← `malloc_atomic`,
      faulting on `0xffffffff00000012`. The `Thread` family's signature is a
      fault inside `pthread_getattr_np` under `stop_world`; this is neither that
      call nor that phase, so folding the two together would be an assumption.
      Both ran mute because only the plain arm carried the diagnostics — now
      fixed, along with the audit that would have flooded them: it reported 262
      live objects as dying per run on exactly this arm.
      **Not reproduced locally**: 15 runs of the failing command at the CI
      parameters, plus the three arms under the full diagnostics, all clean on
      x86_64 Linux. The next sighting is the one that will say something.

- [x] **A full staging table threw away the newest birth — closed 2026-08-22.**
      The record the pre-stop wait runs on was kept in a 64-slot table drained
      only by the collection's own walk, so it held births since the last
      collection rather than births in flight: 65 `Thread.new`s fill it, and at
      200 threads only 73 of 201 births were recorded. The one refused was the
      newest, i.e. the thread inside the window — never waited for, so the world
      stops with it unpublished, neither suspended nor scanned, and anything
      reachable only from its stack has no root (the birth root covers the
      `Thread` object alone). A full table now drains published entries and
      evicts the oldest if that frees nothing; all 201 births are recorded.
      The drain does the work when the threads are alive (6 overflows / 4
      evictions at 100) and cannot help once they have exited (107 / 105 at
      200), which is what the eviction half is for. Gated both ways by
      `make thread-staging` with `GCRY_STAGED_NO_EVICT=1` as the red arm.
      **Still lossy and counted**: `thread_staged_evictions` is a thread that
      will not be waited for.

- [x] **The BSS stopped being a root range above 1 MiB — closed 2026-08-22.**
      The maps parser accepted the executable's BSS only if the mapping was
      under 1 MiB, so a program with more static data than that had every class
      variable and constant slot dropped from the root set. Twenty lines
      reproduce it: an 8 MiB static array, a block stored in it, two
      collections, and the process dies in `IO#encoder` because `STDERR` was
      collected and finalized — fd 2 closed by the collector. The size test was
      also inverted with respect to its own rationale; adjacency to the
      executable's `.data` is what excludes gcry's own anonymous mappings, and
      `each_static_range_excluding_heap` is the second line of defence.
      Removing the cap alone would have moved the hole to `MAX_SCAN_BYTES`,
      where a >64 MiB range was skipped with nothing counted, so static ranges
      are chunked now and the refusal is counted. Gated by
      `make static-bss-roots` at both thresholds, with `GCRY_STATIC_BSS_CAP=1`
      as the red arm.
      **What it did to the numbers — measured 2026-08-23, and they stand.** Any
      affected program was freeing objects it should have kept, so its RSS and
      pause figures were not the collector's, which put every fat-app cut in
      question. Built the way those cuts are built (`-Dgc_none --release`),
      acikturkiye's BSS mapping is **495 616 bytes (0.473 MiB)** against the
      1 MiB cap — read from `/proc/<pid>/maps` on the running process, with
      `/gc-stats` confirming gcry underneath. Its own static data is ~15 KiB
      above the gcry + Crystal baseline of ~480 KiB, so the headroom was never
      close. Two ways to get this wrong, both of which a first attempt did: the
      ELF `.bss` **section** is not the mapping gcry measures, and a non-release
      Boehm build of the same app reports 1 136 696 bytes — over the cap, and
      about a binary no cut ever used.

- [x] **The pthread stack-bounds snapshot stopped at 64 threads — closed
      2026-08-22.** The table the STW scan looks thread stack ranges up in was a
      fixed 64 entries, so a process with a longer thread list bounded the first
      64 in list order and left the rest unscanned on the pthread side, every
      collection. Measured: 82 threads reported `visited=64 read=64` — the pair
      that exists to report exactly this gap, reading clean, because the
      capacity check returned before the visit was counted — with 18 lookups
      falling through to `nil`; 122 threads, 58. It grows now, and the visit is
      counted first, so `read == visited` is load-bearing: 82 → 82/82, 202 →
      202/202, zero misses. **Correction, 2026-09-16: the gate this claimed did
      not exist, and now does.** It said "gated in `process_spec` above the
      initial capacity and broken on purpose with `GCRY_STACK_BOUNDS_NOGROW=1`
      (red at `visited=150 read=130`)" — that break was real when it was
      measured, but the knob appeared in no `spec/`, no `bench/`, no recipe and
      no CI step, so nothing re-checked it and the counters it names were
      asserted nowhere; one of eleven such knobs
      (`bench/log/linux/2026-09-16-orphan-break-knobs/FINDINGS.md`).
      `make stack-bounds-growth` is now the gate, on Linux, aarch64 and Darwin:
      100 threads held live must give `read == visited` with zero capacity
      misses, `--control` stays inside the initial 64 so that equality is
      attributable to growth, and `GCRY_STACK_BOUNDS_NOGROW=1` must make the
      loss **show in both counters** — measured `read` 128 of 204 visited with
      76 misses, because a frozen table that also stopped counting would read as
      full coverage of a smaller process. What is still not measured is
      unchanged: whether a thread past the 64th ever held the only reference to
      something. The gate asserts the coverage, not a defect.
      `bench/log/linux/2026-09-16-stack-bounds-gate/FINDINGS.md`
- [x] **The aarch64 spec flake family — root-caused 2026-09-17.** Five
      examples across three files had failed together ~3 in 30 runs on
      `test (aarch64 native)` while passing 80 of 80 locally, and the spec
      carrying the note said "expected > 0 says nothing about which of
      dormancy's preconditions was missing". The widened state dump answered it
      on the next occurrence: the empties *were* seen fully free
      (`fully_free=1048576`), nothing was live, warm retain was pinned to 0, the
      dormant budget was 64 MiB against 1 MiB, nothing was unmapped and the page
      sizes agreed — so the release path had not run at all.
      `release_empty_chunks_this_collect?` returns false under
      `sweep_multi_mutator?` unless a parallel reclaim knob is on, and
      `sweep_multi_mutator?` counts Crystal's thread list: **one thread left
      running by another example turns the empty-chunk release off**. Randomised
      order and host speed decide whether that happens, which is the whole
      flake. Reproduced with a single extra live thread — `dormant=8 → 0`,
      `unmapped=393216 → 0`, restored exactly by the knobs, which are only read
      on the multi-mutator branch. Pinned at eight sites across six files, every
      spec that enables `release_empty_chunks` rather than the five that failed.
      `bench/log/linux/2026-09-17-empty-chunk-release-flake/FINDINGS.md`
- [x] **Darwin: a process with more than 64 threads never got them back —
      fixed 2026-09-17 (Half 1).** `MAX_STW_SP_SLOTS = 64` in `darwin_stw.cr`
      backs the SP, greg, id and Mach-port tables. `stop_world_threads` suspends
      **every** thread unconditionally but recorded the port only `if
      @@stw_port_count < MAX_STW_SP_SLOTS`, and `resume_suspended_ports` resumed
      only what the table held — so **every thread past the 64th was suspended
      and never resumed**, from a collection that reported success. Measured by
      `make thread-startup-cost` on the Darwin runner: with a collection every
      2 ms through the storm, n=32 finishes in 32.3 ms and n=64 and n=100 both
      exceed a 120 s budget, while the same arms with collections off do 100
      threads in **2.3 ms**. A cliff on the constant, not a curve — the O(n²)
      reading was refuted. This is also what took the Darwin job down through
      `stack_bounds_growth` at 100 threads on 2026-09-16.
      The resume now walks `Thread.unsafe_each` and resumes every non-current
      thread with a non-zero Mach port — the same predicate the stop suspends
      on, so the two walks cover the same set by construction with no bound
      between them. `thread.@suspended` was rejected as the record on purpose:
      it is Crystal's ivar, and if Crystal's own suspend protocol ever writes it
      the record becomes shared state. `stw_threads_suspended` /
      `stw_threads_resumed` count `KERN_SUCCESS` on both sides, so the contract
      is an equality that breaks in two directions — fewer resumes is a frozen
      thread, more is gcry resuming a thread something else suspended — and
      `make darwin-stw-resume` asserts it with 70 threads plus per-worker
      progress. Its red arm is `GCRY_STW_BOUNDED_RESUME=1`, the pre-fix table
      walk, with an 8-thread arm under the same knob so the failure is
      attributable to the bound rather than to the knob. Three arms, bounded
      children, 60 s each; a wedged child counts as the red observation because
      a thread frozen holding the allocator takes the process with it.
      **Verified on the runner** (run 35223283452): hold 142 suspends / 142
      resumes / 0 stalled, bounded 142 / **128** / **7 stalled**, control 18 /
      18 / 0. The difference of 14 is 2 collections × (71 − 64) threads, which
      is the bound stated as arithmetic. The probe's two TIMEOUT cells also
      filled in — collect n=64 now 236.2 us/thread and n=100 60.5 us/thread,
      falling with n exactly as Linux does.
      `bench/log/linux/2026-09-17-darwin-64-thread-cliff/DESIGN.md`
- [x] **An explicit `GC.collect` was usually a no-op under thread load, and
      returned nothing to say so — fixed 2026-09-17.** `Heap#collect` bails on `@collecting`, which
      is set for the whole cycle, so any explicit request made while a peer is
      collecting returns immediately and silently. Measured on 20 hardware
      threads, asking continuously for one wall second: at 8 threads 226 of
      1 969 calls landed a collection, at 32 threads 58 of 571 342, at 70
      threads **6 of 85 682** — about 1 in 14 000, because a cycle there takes
      ~145 ms (p50) and the flag is up for all of it. The other two guards were
      ruled out by measurement rather than by reading: the calling thread's
      `@name` is `DEFAULT-0` and its `@current_fiber` is non-nil.
      So `GC.collect` is not a barrier: a caller who needs a collection to have
      completed has to poll `pause_count`. The fix is to wait for the in-flight
      cycle instead of returning, with `@stw_owner_pthread` distinguishing "a
      peer is collecting" from "this thread is inside a collect" so a collect
      called from a finalizer does not deadlock. Red arm by construction: N
      hard-allocating threads, one explicit call, assert a pause followed.
      **Two of my own claims are retracted in that record**: a call-bounded loop
      of 2 000 001 calls "never landing" sampled five milliseconds of a 145 ms
      cycle, and the 32× throughput collapse from 8 to 70 threads is *not* the
      collector — with `GCRY_DISABLE_AUTO=1` the same threads collapse the same
      way (2470 → 74.6 MB/s), and at 32 threads the run without the collector is
      the slower one. 70 spinning allocators on 20 hardware threads is 3.5×
      oversubscribed and nothing on this host separates the two.
      Also methodological: a harness that calls `collect` and reads a counter
      measures a *window*, not a call. The `stw_capture_no_slot` table's "per
      collect" column is corrected to "per window" in place.
      **Fixed by narrowing the guard, not by adding a wait:** `run_collection`
      already acquires `@post_stw_mutex` at entry, so the early return was the
      only thing preventing the wait. It now fires only when the calling thread
      is inside its *own* cycle — `@collecting` *and* `@collector_pthread ==
      pthread_self()`, read together because neither is sufficient alone — which
      keeps a `collect` from a before-collect callback from deadlocking on a
      mutex that is not recursive. The allocation path is `maybe_collect` and is
      untouched; `collect_a_little` keeps its early return, because a slice that
      blocked would stop being a slice.
      `make explicit-collect-barrier`: 20 consecutive calls with 32 threads
      allocating land 20/20, the same 20 under
      `GCRY_COLLECT_SKIP_WHEN_BUSY=1` land **0/20**, and 20 on an idle process
      land 20/20 so the gate is not passing on movement it did not cause.
      Twenty rather than one because the pre-fix behaviour is probabilistic
      (~1 in 9 850 at this thread count) and one call would pass by luck.
      **It costs what it should:** `thread-startup-cost`'s collect arm asks
      every 2 ms and those calls now collect, so its join time at n=100 went
      85.7 ms → **3638.1 ms** with 11 collections instead of a handful. The arm
      is finally doing what it always claimed. Both affected records are
      annotated as pre-barrier baselines.
      **New property, stated rather than softened:** the call waits, so against
      a thread collecting in a tight loop it can wait a long time —
      `@post_stw_mutex` is a plain `pthread_mutex_t` with no fairness, and the
      gate's own window-holding thread starved the prober for 90 s on a 4-vCPU
      runner before it was given a 2 ms sleep. Returning as soon as a *peer's*
      cycle finishes would bound the wait and is the wrong guarantee: that cycle
      may have snapshotted the heap before the call, so objects unreachable at
      call time can be marked live by it. "Collect now" means a cycle that began
      after the request.
      **The gate's first two shapes both came out wrong on CI and neither
      failure was in the collector**: a control arm that relied on allocator
      contention to hold a collection in flight went green on a 4-vCPU runner,
      and the tight loop that replaced it starved the thread it was measuring.
      The window is now held structurally and observed through
      `heap.collecting?` before each measurement, with
      `asked_without_a_cycle_in_flight` reported so an arm that measured outside
      it says so.
      `bench/log/linux/2026-09-17-explicit-collect-noop/FINDINGS.md`
- [x] **`GCRY_DISABLE_SP_CLAMP` was three effects in one knob, two of them
      undocumented — fixed 2026-09-18.** The orphan-knob census set it aside
      because it *hung* `greg_roots` and `scheduler_roots` rather than failing
      them, and the reason turns out not to be the clamp: the knob also skipped
      `install_stw_sp_capture`, which on Linux installs the `SIG_SUSPEND`
      handler the stop collects its acknowledgements through. 60 s of no
      progress, twice. And it disabled **register roots**, because
      `with_thread_gregs` gated on the same flag — the v0.19.0 missed-root shape
      reachable from a knob whose documented effect is "full pthread range on
      other threads". Measured with the clamp disabled in code rather than by
      env, which isolates that effect: `register candidates from suspended
      threads: 0`.
      The install is unconditional now and the register path gates on
      `@@stw_booted` alone, so the same command that hung exits 0 instantly with
      23 candidates. And the knob stops being an orphan: `samples/stw_sp_clamp`
      passed with `hits=0 fallbacks=2` — a state where the clamp did nothing,
      because its assertion allows a fallback — so it now requires `hits > 0` on
      Linux (Darwin reports zeros by design) and the knob is its red arm in the
      aarch64 job, verified in both directions.
      `bench/log/linux/2026-09-18-sp-clamp-knob/FINDINGS.md`
- [x] **The holders search was Unix-only, and Windows is where it is needed —
      ported 2026-09-17.**
      `poison_holders.cr` opens with `{% skip_file unless flag?(:unix) %}`, so
      `Gcry::PoisonHolders` does not exist on Windows — which is the only
      platform where `make tls-roots`'s control arm has actually come out
      INCONCLUSIVE, and therefore the only platform that cannot say where the
      stale copy is. Found by breaking two Windows jobs with the call (run
      35224827564, `undefined constant Gcry::PoisonHolders`).
      The search's three sources — the explicit root set, every live block,
      every fiber stack — are not inherently Unix; the `skip_file` is about the
      fault-time path it was written for, which runs out of a SIGSEGV handler
      through `RawOut`. Porting the walks without the handler entry is the work.
      Meanwhile `make windows-typecheck` exists, cross-compiling what
      `ci/windows.ps1` builds for both Windows targets in 8 s, because
      `darwin-typecheck` had covered that class of mistake since 2026-08-22 and
      Windows had no equivalent.
      **The gate was conservative, not a dependency.** `Platform.thread_sp` and
      `snapshotted_stack_bounds` exist on all three platforms, `last_stop_sp`
      was already behind `{% if flag?(:linux) %}`, and `@system_handle` is the
      right type per platform because each `thread_sp` takes its own. Opening
      `skip_file` to `win32` type-checks on both Windows targets with no other
      change, and `tls_roots.cr` now calls the search unconditionally.
      **Compiling is not running**, and the only Windows path that reached the
      search was the failure path it was added for — a first execution inside an
      already-failing gate turns a bad reading into a crash. `ci/windows.ps1`
      now also runs `bench/holders_find.cr`, whose answer is known, so the walk
      is exercised there while green. **Verified on Windows** by that step (run
      35234720654): holders found at all three size classes and none for the
      control, so the walk works there rather than merely compiling. Still
      unverified on that platform: the *stack* half of the search, since
      `holders_find` builds its holders in the heap, and the INCONCLUSIVE path
      itself, which needs the arm to fail again.
      `bench/log/linux/2026-09-17-tls-roots-inconclusive/FINDINGS.md`
- [x] **`make tls-roots`'s control arm came out INCONCLUSIVE on Windows —
      explained and settled 2026-09-17.** The arm allocates a block, holds it nowhere, wipes 16 KiB of
      stack and collects twice; the block must die, which is what makes the
      other arm's survival attributable to the thread-local instead of to the
      harness. On run 35223760476 it survived — `victim live?=true intact=true`
      — and the harness failed the job, correctly: an arm that cannot
      discriminate has proven nothing. Not caused by the commit it failed on
      (a spec-helper change) and the same job was green an hour earlier, so it
      is a probabilistic control rather than a regression.
      Windows is the likely platform for it because `wipe_stack` cannot reach
      the **register file** and that platform's STW capture scans more of it
      than any other: `GREG_WORDS = 80` there is RAX-R15 *plus* the 512-byte
      FP/XMM save area, against 16 GP words on Linux x86_64 — and a fill loop
      is what a compiler vectorises. A reading, not a measurement.
      So the arm now calls `Gcry::PoisonHolders.search` when it comes out
      INCONCLUSIVE: the next occurrence names the slot (the wipe is too small)
      or says `holders — none`, which for this arm leaves the register file,
      where no wipe can help and the harness would have to stop materialising
      the pointer in a register at all. Verified locally against a deliberate
      stack holder: 8 words across 4 stacks, exact fiber and slot addresses,
      roots and heap explicitly clean.
      **It named a stack, not a register** (run 35243383054): roots 0, heap 0,
      **8 words across 5 stacks**, five of them above the running fiber's
      `stack_top` — live frames, which `wipe_stack` cannot reach because it
      overwrites the dead ones below the current SP. That is the codegen fact
      `bench/greg_roots.cr` already records for its end-to-end arm, so the
      register hypothesis is retracted and no wipe can fix it.
      The arm therefore reports instead of failing **when the search finds a
      holder**, and still fails when it finds none — which would mean something
      keeps the block alive that the search cannot see, with the TLS slot on
      that arm null. The two arms that gate the behaviour, TLS-only survival and
      `GCRY_TLS_ROOTS=0` losing the block, are unchanged. `PoisonHolders.search`
      returns its holder count now so the decision rests on evidence rather than
      on the survival alone.
      `bench/log/linux/2026-09-17-tls-roots-inconclusive/FINDINGS.md`
- [x] **The 64-slot bound cost Darwin its register capture and Windows its
      collection (Half 2) — two reverts, then landed 2026-09-18.** `slot_for` returns −1 past the table, so those threads
      are suspended with no SP clamp and no registers — a reference live only in
      the 65th thread's registers is not a root, which is the v0.19.0
      `each_thread_greg` shape on a new axis. Now instrumented rather than read
      off the code: `stw_capture_no_slot` counts a claim that found the table
      full, and on Linux x86_64 it is **exactly 0 every collect at 9 and 33
      threads and +70 per collect at 101** — about two per uncovered thread,
      since the collector reserves a slot and the handler claims one. Not
      demonstrated collecting a live object; the loss is in the coverage.
      One bound, three behaviours, which was the surprise: **Windows refuses the
      stop** (the count is checked before the suspend and
      `raise_thread_suspension_error` already says "or exceeded 64 threads"), so
      it never suspends a thread it cannot record — the counter is a structural
      zero there. **Linux admits the stop and loses the capture**, by the
      explicit `SUSPEND_NO_SLOT` decision to cost the thread its clamp rather
      than the stop. **Darwin hung**, which was Half 1.
      The design: the claim bitmask has to go (an `Atomic(UInt64)` cannot
      address past 64 slots — a per-slot `Atomic(UInt8)` replaces it), the table
      grows at collection entry via `LibC.realloc` and never inside the stop
      (malloc under a stopped world is the 2026-08-10 six-hour hang), Darwin
      hands the slot index through instead of re-deriving it because `slot_for`
      is a linear scan called twice per thread and is the next cliff once the
      ceiling lifts, and Windows has to be given something to do other than
      refuse. The gate asserting `stw_capture_no_slot == 0` lands with the fix,
      not before: on a tree that can reach 64 threads it is supposed to be
      non-zero today. **Unexplained and recorded as such:** at 71 threads the
      counter reads 10 from startup and then +0 for three explicit collects,
      when 6 threads should go uncovered each time — a given stop appears not to
      suspend every thread on the list (`stw_records` 138 across three collects
      of 71), and nothing in the design rests on why.
      No user-visible sighting: every observation is from a harness asking for
      ≥64 threads on purpose, and `Parallel` defaults to capacity 1.
      **Two premises were checked before any code changed, and both moved the
      work.** A missing SP clamp is *conservative*: `scan_pthread_stack` with a
      nil SP walks the whole stack. And on Linux the registers are on the
      interrupted thread's own stack — the suspend handler is installed with
      `SA_SIGINFO` and **no `SA_ONSTACK`**, so its `ucontext` is there and the
      unclamped walk covers it. So Linux loses precision, not roots, and the
      claim that it loses roots (made here, in the design, and in v0.26.1's
      CHANGELOG) is retracted.
      **Shipped for Darwin and Windows.** Both tables now grow at collection
      entry via `LibC.malloc`, doubling from 64, sized from
      `Thread.unsafe_each` plus eight slots of slack, before the first suspend —
      never inside the stopped world. No copy, since every slot is per-STW. If
      the allocator refuses, the old table stays and `stw_capture_no_slot`
      counts the shortfall rather than the collection being failed, which is
      exactly the trade Windows used to make in the other direction: it
      *refused the stop* at the 64th thread, so a 65-thread process could not
      collect at all. The 64-bit claim mask — which **was** the bound, a
      `UInt64` cannot address a 65th slot — is one plain byte per slot, with no
      CAS, because on these two platforms `slot_for` runs only on the collector,
      one thread at a time. Both stop loops hand the slot index down, so the
      linear `slot_for` runs once per thread instead of twice.
      **Linux is left alone deliberately**, not for convenience: its loss is
      precision, and its table is the one a suspend handler claims from — a
      stale handler touches it *before* the epoch declines the delivery, so
      growing it needs atomics on `malloc`ed memory and a table that is never
      freed. That is a separate change with a different risk profile.
      `make stw-capture-coverage`: 80 threads with zero failed claims, the same
      pinned by `GCRY_STW_FIXED_SLOTS=1` where they must be non-zero, 8 threads
      under that knob where they must be zero; capacity growth asserted so a
      zero cannot be a table that never had to cover anyone, and
      `thread_greg_words_total` required to move so an arm that captured
      nothing fails its precondition. **Not verified on either platform by me**
      — no host here; four cross-targets type-check, the Linux suites and every
      STW gate still pass, and the Darwin and Windows CI jobs are the first
      execution.
      **Reverted the same day.** `29b74f0` crashed the Darwin job —
      `Process terminated because of an invalid memory access` in
      `make chunk-search-race`, a step that was green on the commit before — and
      with no Darwin host here a second blind push was not worth another red
      tree. The measurements stand; the code is out. The likely cause and what a
      re-land has to do differently are written down: `grow_stw_table` **frees**
      the old tables, and static arrays tolerated concurrency that
      malloc'ed-and-freed ones do not — an unsynchronised `@@stw_booted` lets
      two threads boot and one free the other's table, `Platform.thread_sp` runs
      outside any stopped world for library heaps (which is what
      `chunk_search_race` builds), and `@@stw_capacity` is published in a
      separate store from the pointers, so aarch64 can pair a new capacity with
      an old pointer. Never freeing, and publishing capacity and arrays as one
      allocation behind a single pointer store, is the shape to try next.
      **Second attempt, 2026-09-18, also reverted — and it moved the
      question.** The table went into one shared module (`stw_slots.cr`) with
      eight specs that run on any platform, and that reproduced the *first*
      attempt's crash here in under two seconds: readers walking the table while
      it doubles are 8 of 8 green as shipped and fault **3 of 3** when the growth
      frees its predecessor. So that crash was never Darwin-specific.
      Darwin failed anyway, deterministically — `make chunk-search-race`, an
      invalid memory access after all nine arms printed `ok`, on the run and on a
      rerun, with the unit suite (including the new specs) passing. **And the
      changed code cannot execute in that binary**: the harness is built without
      `-Dgc_none`, `install_stw_sp_capture` is reachable only from
      `gc_override.cr`, every table entry point returns early unless
      `@@stw_booted`, and its probes fake the stopped world rather than
      suspending anyone. So the mechanism is indirect — the ~17 KiB of static
      arrays the change removes from `Gcry::Platform` moves the writable segment
      this platform scans as conservative static roots, or the harness has a
      latent teardown fault the layout change reaches.
      **Bisected on a branch, 2026-09-18, with master green.** `on: push:` has
      no branch filter, so `half2-darwin-probe` gets the full matrix without the
      tree going red. Four rounds: the re-land red with one line; the report
      installed in the parent plus boundary markers, which showed the **parent**
      crashing *after* `exit 0`, with every child printing `ok` and no `FAIL`
      line; a ~17 KiB BSS pad restoring what the change removed from
      `Gcry::Platform`, still red — **layout refuted**; and `stw_slots.cr`
      present with the platform files back at master's, **green** — so the
      module, its spec and the requires are innocent and the **Darwin wiring**
      is the trigger. No `gcry:` report line appears even with the handler
      installed in the parent, which reads as a fault on a thread that never got
      an alternate stack (the report needs ~4.7 KiB and `install_alt_stack` is
      per-thread) — a reading, not a measurement. Next round pushed:
      `darwin_stw.cr` at the re-land's version with the parent calling
      `LibC._exit(0)`, which separates Crystal's exit path from everything
      before it — and it came back **red**, so it is not the teardown either:
      `_exit` never ran, or the process would have died silently with status 0.
      What every round is consistent with is a fault on a thread other than the
      main one as the parent finishes, which is also why no `gcry:` line
      appears. Parked there, with master green and the branch holding the
      instrumented harness; the next split is inside `darwin_stw.cr`, one bit
      per round, and the first one to try is the pre-suspend
      `Thread.unsafe_each` count the re-land added, since it is the only new
      code on a path a library build can reach.
      **Found, and it was one line of declarations.** The message that cost two
      reverts and eight probe rounds — `Process terminated because of an invalid
      memory access` — is `Process::Status#description`, printed by the
      `crystal` driver (`command.cr:356`) about a program *it ran*. So it was
      never `chunk_search_race`'s parent dying at exit: the step's next command
      is `crystal spec -Dgc_none process_spec`, and that binary died **at
      startup, before any output**. Every attribution before that is retracted,
      and it is why `_exit(0)`, a 16 KiB pad and restored statics all stayed
      red.
      The defect: `Gcry::StwSlots` declared its class variables with
      initializers, and a class variable with an initializer is set up lazily
      behind `Crystal.once` — while Darwin's `install_stw_sp_capture` boots the
      table from `GC.init`, before `Crystal.main` sets that machinery up.
      `linux_stw.cr` documents exactly this rule, three files away. Fixed with
      the pattern the platform files already use: `uninitialized` declarations,
      a plain `@@booted` literal as the gate, defaults in `configure`, every
      reader gated. Darwin green with the full wiring.
      **So Half 2 is in**: one shared `Gcry::StwSlots` for Darwin and Windows,
      one `LibC.malloc` block published by one pointer store, grown at
      collection entry and never freed, the claim mask gone, the slot index
      handed down so the linear scan runs once per thread, Windows' refusal at
      the 64th thread gone, and Linux unchanged for the measured reason.
      `make stw-capture-coverage` gates it on both platforms with
      `GCRY_STW_FIXED_SLOTS=1` as the red arm, and `spec/stw_slots_spec.cr`
      covers the table on every platform — including a reader-during-grow
      example that faults 3 of 3 if the growth frees its predecessor.
      **Verified on both platforms, in situ** (run `35381875960`, 20 jobs
      green). `make stw-capture-coverage` on the runners:

      | platform | threads on list | capacity | no_slot |
      |---|---|---|---|
      | Darwin | 82 | 128 | 0 |
      | Darwin, `GCRY_STW_FIXED_SLOTS=1` | 82 | 64 | **34** |
      | Windows | 83 | 128 | 0 |
      | Windows, `GCRY_STW_FIXED_SLOTS=1` | 83 | 64 | **36** |

      and the same knob inside the table's capacity (10–11 threads) loses
      none, so the zero is about the growth and not about the knob.
      `make stw-slots-grow-race` in the Linux job carries 4 flat-out readers
      across 12 doublings 3/3 and kills them 3/3 with
      `GCRY_STW_SLOTS_FREE_OLD=1`.

      **Three more things had to be fixed to get there, and none was the
      table.** A `Crystal.once` initializer on `@@stw_handles`, read inside
      the stopped world, where a suspended thread can hold that mutex —
      `make once-guard` is mechanical about that rule now, in the four files
      the collector reads from `GC.init` or a stopped world. And two tests
      that pinned the bound: `spec/platform_windows_spec.cr` asserted that 65
      threads make `stop_world` raise, so when it succeeded the assertion
      failed **with the world stopped** and then joined 65 suspended threads —
      every Windows job hung for its full 20-minute budget, three runs — and
      the same pin in
      `process_spec/regression/9_windows_suspension_capacity_spec.cr`, whose
      failure-path coverage is kept by `GCRY_STW_TEST_FAIL_SUSPEND=1` instead.
      Windows-only spec files cross-compile in `make windows-typecheck` now.
      **The next step was a report, not a third attempt, and it is in.** That
      harness is a library build, so gcry installed no SIGSEGV handler in it, and
      two runs of a deterministic fault produced one line with no address, no
      backtrace and no release ledger — and no way to tell which of nine arms
      died, since each prints its own `ok` before exiting. Both are fixed:
      the harness installs the report (the one-liner `large_cache_race.cr` and
      `dormant_flush_race.cr` already had) with the recipe setting
      `GCRY_SEGV_REPORT=1`, and the parent names the failing arm and separates a
      non-zero exit from a timeout. The same variable is now set for
      `dormant-flush-race`, `large-cache-race` and `find-block-race`, which were
      printing one line for a fault as well.
      `bench/log/linux/2026-09-18-crash-legibility/FINDINGS.md`
      `bench/log/linux/2026-09-17-darwin-64-thread-cliff/FINDINGS.md`,
      `…/DESIGN.md`, `…/HALF2-REVERT.md`
- [x] **100 threads take over 120 s to start on the Darwin runner — answered
      2026-09-17, and it was not thread startup.**
      Measured 2026-09-17 by `bench/stack_bounds_growth.cr`'s bounded arms:
      `threads held: 100` never printed, so all 100 never got *running* — this
      is thread startup, not a collection — while the same harness's 8-thread
      arm was instantaneous and Linux does 100 in about two seconds. A ~60×
      discrepancy, on both arms that asked for 100. Not asserted, worth
      testing: `Thread.new` allocates, an allocation can trigger a collection,
      and Darwin's stop-the-world suspends **each** thread with a Mach
      `thread_suspend` / `thread_get_state` pair rather than one signal
      broadcast, so a thread-creation storm would cost O(n²) there and not on
      Linux. If that is it, it is a Darwin scalability finding about the
      collector and not about the harness that tripped over it.
      **The probe is built and the Linux baseline is in (2026-09-17):**
      `make thread-startup-cost`, three arms over n = 8/32/64/100, each (arm, n)
      pair its own bounded child so a hang at large n does not cost the small-n
      data. Linux: 100 threads reach running in **2.8 ms** and per-thread cost
      *falls* with n on every arm (x0.16 to x0.22) — nothing quadratic here. A
      collection during the storm costs about **30x per thread**, and the
      collect arm's cost per collection rises 2.6 → 7 ms as the live thread
      count goes 8 → 100, which is the O(n) per stop any collector owes; what
      is open is Darwin's constant. The probe also had to grow a third arm to
      be worth anything: `auto=on` and `auto=off` both report
      **`collections=0`**, because 100 `Thread.new` calls never reach the
      threshold, so the knob separating them does nothing and the two rows are
      one measurement twice — only the forced-collection arm bears on the
      prediction. It runs `continue-on-error` on Darwin, and **the evidence is
      its log, not its step conclusion**.
      `bench/log/linux/2026-09-17-thread-startup-cost/FINDINGS.md`,
      `bench/log/linux/2026-09-16-stack-bounds-gate/FINDINGS.md`
      **Darwin answered it:** startup is *not* slow there — 100 threads reach
      running in **2.3 ms** with collections off, the same order as Linux. What
      hangs is a collection during the storm, and it hangs at exactly 64
      threads, which is `MAX_STW_SP_SLOTS`. The O(n²) hypothesis is therefore
      **refuted**: it is not a cost that grows, it is a bound that is crossed.
      The item above carries the defect.
      `bench/log/linux/2026-09-17-darwin-64-thread-cliff/FINDINGS.md`
- [x] **`make stack-bounds-growth` is not enabled on Darwin — settled
      2026-09-17, and not for the reason first given.** Its first CI run
      took the macOS job down: 18m37s, cancelled at the job's 20-minute cap,
      after the two root gates before it finished in 3 and 4 seconds — while
      Linux x86_64 and aarch64 Linux both passed it. Exactly the hazard recorded
      the day before about `GCRY_DISABLE_SP_CLAMP`, in a gate written the day
      after. The leading suspect is the harness: it held 100 threads alive on a
      200 us poll, 5 000 wakeups per thread per second, which is unremarkable on
      a 20-thread host and plausibly pathological on a 4-vCPU runner. The poll is
      25 ms now, which costs the harness nothing. That fix is **untested on
      Darwin**, so the arm stays off: what closes this is one Darwin run wrapped
      in `timeout`, the way the aarch64 job already wraps every gate, so a hang
      fails a step in a minute instead of cancelling twenty. If the poll turns
      out not to be it, the next suspect is Darwin's per-thread Mach
      `thread_suspend` / `thread_get_state` stop against Linux's signal
      broadcast at 100 threads, which would be a finding about the collector.
      **The measurement is now scheduled rather than argued about (2026-09-17),
      and the first attempt at it failed the same way everything else here
      has.** `timeout 180` in the Darwin step: macOS has no `timeout(1)`, so the
      step died with exit 127 in 0 seconds and `continue-on-error` reported it
      `success` — a measurement that measured nothing and said green. The bound
      is in the harness now, each arm a `BoundedChild`, which is where a gate
      that can hang has to carry it; at a 1 s budget the parent exits 1, so the
      bound has its own positive control. Darwin runs it `continue-on-error`
      for one more reading, and **its step conclusion is not the evidence — the
      log is**. That reading came back and closed the item the other way: the
      poll was **not** it (100 threads still exceed 120 s at 25 ms), and the
      gate has nothing to assert on Darwin regardless — `darwin_stack.cr`
      queries the thread descriptor at lookup time, so there is no table to
      grow and `stack_bounds_visited` / `read` / `capacity_misses` are **zeros
      by design**. The claim that "the arms are not Linux-only" was read off
      three platforms *declaring* the same methods; they declare them returning
      zero, which is the `each_thread_greg` stub shape v0.19.0 was about. The
      8-thread arm reported `visited=0 read=0` and the harness's precondition
      failed on it — the part that worked. The harness skips non-Linux with
      that reason now, the Darwin arm is removed for cause, and the 120 s hang
      is a separate item above. That is the arrangement the Darwin soak smoke used until four
      runs measured its bound and it was promoted to gating. Promote or remove
      once a run reports.
      `bench/log/linux/2026-09-16-stack-bounds-gate/FINDINGS.md` **What is not measured** is whether a thread past
      the 64th ever held the only reference to something: the loss is a
      documented half of that thread's coverage, and no arm has yet shown a
      block dying of it.

- [x] **The coverage audit's residue is labelled — it is the in-flight
      population, and "4 a run" was a sample.** `GCRY_UNOWNED_COVERAGE_AUDIT=1`
      matches fiber-stack-shaped mappings against fibers, pools and dying-fiber
      slots, and what it could not account for turns out to be exactly the
      regions the in-flight arm walks: measured on `nested_spawn_uaf`,
      `accounted + not` equals `maps_inflight_walked` in every run
      (5411 + 6 = 5417, 5328 + 6 = 5334, 5310 + 36 = 5346). So the split is not
      "known versus unknown" but "parked in a `Thread#dying_fiber` slot versus
      not", and the unparked half is the population `GCRY_MAPS_INFLIGHT_ROOTS`
      exists for.
      Three corrections to the original reading. It is **not 4 a run** — 1 to 36
      on the same harness across runs, so the number was one draw and not a
      constant. It **cannot be thread stacks**, and the reason is structural
      rather than measured: the geometry test looks for
      `STACK_SIZE - PAGE_SIZE` = 8 384 512 bytes, and a Crystal thread's stack
      maps exactly `STACK_SIZE` = 8 388 608 — one page apart, so a thread stack
      never reaches the audit at all. (The check for them is kept as a tripwire,
      because that page is an accident of where glibc puts the guard and not a
      guarantee; a non-zero count would say a libc has made the two shapes
      identical. Its zero is by construction and is documented as such — an
      earlier version of this item offered that zero as a measurement, which it
      never was.) And it needs a **Parallel** execution context under concurrent
      spawning: a quiesced single-context program reports 0 uncovered before and
      after a spawn storm.

- [x] **`live_objects`, `total_bytes` and `bytes_since_gc` lose updates — closed
      2026-08-20.** The counters flip to atomic the moment a second thread is
      created (`GC.pthread_create`, before that thread can allocate), so a
      program that cannot race keeps the cheap path. Gated both ways by
      `make heap-counters`: four threads, 300 000 allocations each, GC disabled
      — the old path loses **5 723 of 1 200 000** and the new one loses **0**.
      The cost the old comment was defending does not exist on x86_64, where
      `set(get + n)` compiles to `mov; inc; xchg` and `xchg` to memory is locked
      whether you ask or not, against a single `lock incq` for the atomic:
      interleaved and pinned, 55.69 / 55.47 / 56.13 ns per allocation for plain
      / atomic / relaxed, indistinguishable. On **aarch64** it does exist —
      `ldar; add; stlr` against an `ldaxr/stlxr` retry loop — which is why this
      flips on a second thread rather than shipping on.
      `bench/log/linux/2026-08-20-heap-counter-cost/FINDINGS.md`


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
      **It has now run on a Darwin host (2026-08-15), and four of the five arms
      hold** — the macOS job could not reach this step until the soak-smoke
      failure ahead of it was fixed:

          page size 4096, region 256 pages
          untouched:  256/256 skippable;     dispositions none×256
          written:    256/256 not skippable; dispositions PRESENT|REF|DIRTY×256
          zero-proof: 27/256 skippable, 0 of them non-zero
          reclaimed:  0/256 skippable, 0 non-zero; dispositions PRESENT|0x800
          paged-out:  0 of 256 written pages left residency (no pressure requested)
          VERDICT: INCONCLUSIVE

      So the disposition does separate untouched from written, and every page it
      called skippable read back zero. What is still unverified is the only case
      the soundness argument turns on: a page that **leaves residency with its
      contents intact**. The runner will not compress on its own, so that arm
      returns INCONCLUSIVE and exits 0 rather than claiming a pass it could not
      produce. `page_query_pressure` is now a `workflow_dispatch` input (default
      0, which is what every push runs) so the arm can be attempted; the wiring
      existed in the Makefile and had no way to be set from CI.
      **First attempt: 2048 MiB, still INCONCLUSIVE** — 0 of 256 written pages
      left residency. `macos-latest` has ~7 GB, so 2 GB of churn was never going
      to pressure it. **And the probe was measuring in the wrong unit**: `PAGE`
      was hardcoded `4096_u64`, so the `page size 4096` it printed was that
      constant and not a reading — the probe never asked the host.
      `Platform.host_page_size` in the collector already records Apple Silicon as
      16 KiB, which if that is the runner makes the region a quarter of its
      intended size, every query answered four times over, and the eviction count
      a count of 4 KiB slices. It now calls `sysconf(_SC_PAGESIZE)` and prints
      the region in KiB, so the next Darwin run reports the host's page size
      instead of the probe's opinion of it — and that number is what decides how
      the eviction arm has to be sized.
      **Measured: `page size 16384 (sysconf), region 256 pages, 4096 KiB`.** The
      runner is Apple Silicon and the probe had been a factor of four out. The
      cost was not cosmetic: the zero-proof arm — the one the soundness argument
      rests on — went from **27/256 skippable to 219/256**, so it now exercises
      eight times the pages it did while reporting the same verdict. Every arm's
      qualitative result is unchanged (untouched skippable, written not,
      every skippable page zero, `MADV_FREE_REUSABLE` zero); what changed is how
      much they cover. The eviction arm is still the open one.
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
- [x] **Windows x86_64 + ARM64 process GC** (Phase 2) — native memory, PE roots,
      thread suspension/context capture, and CI. [Limits and testing](docs/WINDOWS.md).

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
- [x] **Windows x86_64 + ARM64 process GC** — native backend + unit/process/sample CI
- [x] **CI for all platforms** — Linux x86_64 + aarch64, macOS arm64, Windows x86_64 + ARM64
- [ ] **Benchmark regression alerts** — GitHub Action comparing PR vs baseline perf
- [ ] **Crystal compiler PR: `-Dgc_gcry` flag** — opt-in flag recognized by the compiler
      (no-op alias for `-Dgc_none`; ecosystem signal that gcry is real)
- [ ] **Security / fuzzing** — documented fuzz hours, crash-free stress runs
- [ ] **good-first-issue grooming** — Windows benchmarks, benchmark workloads, specs
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
      registry was **left alone**, as were the blacklist / chunk-index growth.
      The rule that survives is narrow — do not ask glibc about a suspended
      thread — and `pthread_getattr_np` was its only instance in the collect
      path. `Platform.push_range`'s realloc inside `scan_static_roots` was
      left alone here too, and is **gone** as of 2026-09-04: the resolve is
      eager in `GC.init` on both platforms and the range table is a fixed
      `StaticArray`, so nothing on that path allocates or raises at all
      (`bench/log/macos/2026-09-04-static-root-init-once/`).
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
- [ ] **What crashed the 2026-08-10 soak.** *(2026-08-15: three readings closed
      by audit, one survives —
      `bench/log/linux/2026-08-15-segv-write-path-audit/FINDINGS.md`.* gcry writes
      outside its own chunks in exactly two places, and **neither was active**:
      the parked-fiber scrub was already default-off in that build (`93776f4` is
      an ancestor of `d36effe`), and the soak's disappearing links point at a
      frame that never returns. **No chunk was released** either —
      `release_empty_chunks_this_collect?` is false under multi-mutator unless a
      Parallel reclaim knob is set, and both default off — so "a valid pointer
      into an unmapped chunk" is out. The soak calls no `GC.free`, so "an
      explicit free of a live block" is out. What survives is a block freed by
      the **sweep** while still referenced, i.e. a missed root. Note the two root
      defects fixed on 2026-08-15 cannot be it: the soak sets no
      `GCRY_AUTO_LAYOUTS`, so its `Fiber` / `GlobalQueue` / `Runnables` are
      scanned word by word and the queue chain was covered either way.) `Invalid memory access at
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
- [ ] **Windows parity** — process GC ships since #38 (x86_64 MSVC, ARM64 GNU); parity still needs the incremental barrier (no soft-dirty), workload benchmarks, and fork/signal-diagnostic equivalents
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
