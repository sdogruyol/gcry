# simdgc → gcry

Plan: `/home/steve/.claude/plans/recursive-wibbling-tulip.md`
Source: `simd_plan/gcry-simdgc-plan.md`
Branch: `simdgc`

Prior art that bounds this work — read before touching the allocator:
- `bench/log/linux/2026-08-01-ec4-alloc-bits/summary.md` — REJECT, per-chunk alloc
  bitmap, `/json` 54k → 44k.
- `bench/log/linux/2026-08-01-ec4-used-count-v2/summary.md` — REJECT, 76.6% → 69.2%.
  "Accounting that enables skip is not free on the HTTP alloc path."

## Phase 0 — kernels and CPU dispatch

- [x] `src/gcry/kernels.cr`: `def_kernel` macro, scalar + avx2 + avx512 clones
- [x] CPU detection (`cpuid` leaf 7 + `xgetbv` on x86_64; constant on aarch64)
- [x] `GCRY_SIMD=off|scalar|neon|avx2|avx512` override, clamps down never up.
      Read with `LibC.getenv` — `ENV[]` allocates and can SEGV in `GC.init`.
- [x] `llvm.prefetch.p0` binding; `prefetcht0` confirmed in asm
- [x] Kernels: `sweep_words`, `popcount_words`, `all_zero`, `range_any`
- [x] `spec/kernels_spec.cr`: scalar ≡ every tier, ~6.7e7 bit decisions. 11 green.
- [x] IR gate: `<4 x i64>`+ctpop.v4i64 (avx2), `<8 x i64>`→`vpopcntq` (avx512)
- [ ] aarch64 IR gate `<2 x i64>` — CI only, no local arm64 host
- [x] `make kernels-broken` purpose-broken gate, **observed red** (4 failures)
- [x] `bench/micro/kernels.cr` + `make bench-kernels`: AVX2 sweep 66.2 GB/s L2,
      26.7 GB/s DRAM vs a bar of 20. Tiers converge at DRAM as predicted.
- [x] `docs/HARDENING.md` entry for `GCRY_SIMD`; `make knob-doc-check` ok (148)
- [x] FINDINGS: `bench/log/linux/2026-09-03-simdgc-phase-0-kernels/FINDINGS.md`
- [x] `make spec` / `make invariants` clean — 181 examples (170 baseline + 11 new), 0 failures
- [x] `make lint` clean — 101 inspected, 0 failures
- [x] `spec/all_specs.cr` requires kernels_spec (ASan/kcov entrypoint); `-Dasan` builds

## Phase 1 — per-chunk mark bitmap

- [x] `ChunkHeader` gains `data_offset` + `bitmap_words` (SIZE 24 → 32) — 09edc19
- [x] `data_offset < Platform.host_page_size` pinned by spec (1056 B / 2080 B)
- [x] Magic reciprocal + exhaustive spec vs `//`; ceiling 64 MiB clamped in
      `gc_override`. Tightest class first fails at 86.3 MiB.
- [x] Large chunks keep `data_offset == SIZE` → all 12 `header - SIZE`
      back-references correct with no edit
- [x] R6: `find_block` + `owns_user_pointer?` off the hardcoded offset, spec-pinned
- [x] `GCRY_BITMAP` knob read in `Heap#initialize` via `LibC.getenv`; `bitmap_marks=`
      setter refuses to change once chunks exist (data_offset is baked per chunk)
- [x] `map_chunk` carves geometry; mmap zeroing means bitmaps start clear
- [x] `chunk_marked?` / `chunk_set_mark` (atomic OR + relaxed pre-load) /
      `chunk_clear_marks` (wholesale only)
- [x] Large chunks stay on the header generation — one object each, and a bitmap
      region would move `data_start` and break 12 back-references
- [x] R1 atomic OR ships ON
- [x] R2 no per-bit clear; `clear_all_marks` zeroes wholesale at cycle start
      (minors keep old-gen marks, matching `clear_nursery_marks`' contract)
- [x] R3 `barrier.cr:222` routed through `heap_set_mark`; `heap_dump.cr` and
      `thread_list_tripwire.cr` through `marked_for_report?` / `heap_marked?`
- [x] R5 fast `(chunk, ordinal)` pair + slow `(header)` wrapper; sweep's ordinal
      is a counter, and `find_block_with_chunk` keeps mark off a second lookup
- [x] Delete `mark_bitmap.cr` and `-Dgcry_side_bitmap` — gone, along with the
      `@@mark_bitmap` global, the growth/headroom machinery in `collect.cr`
      (`ensure_bitmap_covers`, `note_bitmap_growth`, `compute_bitmap_growth_avg`)
      and the `GCRY_BITMAP_RETAIN_OLD` arm that only configured it
- [ ] Spec: same workload under both representations, same live set
- [ ] Run every gate under `GCRY_BITMAP=1`
- [x] NO `occ`, NO allocator change in this phase
- [ ] Gate: Kemal `/json` flat, RSS flat — `wrk` now installed, baseline cut in flight

## Landed alongside (not part of the plan)

- [x] **`master` bug fixed** — `release_large_freelist_pages_locked` madvised the
      page holding its own `ChunkHeader`/`BlockHeader`. Branch
      `fix-large-freelist-madvise` off master, merged into `simdgc`.
      `madvise_range_ok?` now bounds on `data_start`, not the chunk base, so the
      whole class is caught rather than this one instance.
      Gate `make large-freelist-madvise`: default arm 0 rejects / 4.4 MB
      released, control arm (`GCRY_LARGE_RELEASE_FROM_BASE=1`) **119 of 119
      refused**. FINDINGS at
      `bench/log/linux/2026-09-03-large-freelist-header-madvise/`.
- [x] **16-byte allocation alignment** — gcry returned 8-mod-16 pointers for
      every allocation, small and large (140/140 measured at c62f722), against a
      platform `max_align_t` of 16. Fixed as a side effect of ChunkHeader
      24→32; pinned by spec so it cannot silently regress.
- [ ] Latent sibling noted, not fixed: dormant flush at `collect_sweep.cr:612`
      computes `finish = data_start + mapped_bytes`, overshooting the chunk end
      by `data_offset`. Harmless today only because `end_page` rounds back down.

### Mark-clear design (settled by reading, not assumed)

`clear_nursery_marks` retains old-generation marks across a minor on purpose
(`collect_mark.cr:744` — "remain valid"), and a minor bumps no generation. So:

- Minor: zero nursery chunks' mark bitmaps only. Matches today.
- Major: old chunks may still hold marks from the last major *if a minor ran
  since*. So `clear_all_marks` is a no-op when no minor has run since the last
  major — which is **every collection in the default config, nursery being
  off** — and a full per-chunk zero otherwise. One boolean, free on the default
  path, instead of an unconditional 4 MiB-per-GiB memset (~0.2 ms/GiB).
- Sweep zeroes each chunk's mark bitmap wholesale after its walk (R2), never
  per bit.
- DORMANT transition and `revive_dormant_chunk` both zero the bitmaps: a
  fully-free chunk sweep skips could otherwise carry a stale mark from the
  FREE+marked TLAB-claim path (`collect_mark.cr:101-123`).
- `GCRY_DEBUG_INVARIANTS` audit: after `clear_all_marks`, every mark bitmap is
  zero. Turns a silent divergence into a finding.

### Concurrency (R1/R2), from the call-site census

11 `heap_set_mark` sites. **7 are mutator-side allocate-black** —
`heap.cr:765,869,1228,1239` and `tlab.cr:376,611,682`, all
`if @incremental_marking || @collecting`. 64 blocks share a bitmap word, so a
non-atomic `|=` there drops a *different* object's mark. Atomic OR ships ON.

3 real `heap_clear_mark` sites: `collect_sweep.cr:340` (large — one bit in
`flags`, no sharing, fine) and `:862`, `:886` (inside `sweep_small_blocks` —
both must become the post-walk wholesale zero).

### Phase 1 hard requirements (from design review)

- [ ] R1 `heap_set_mark` uses atomic OR (relaxed) + skip-if-set load. Ships ON.
- [ ] R2 no per-bit clear; marks consumed wholesale per chunk
- [ ] R3 `barrier.cr:222` routed through `heap_set_mark`; static `BlockHeader` mark
      API deleted in the bitmap build (compile error, not wrong answer). Same for
      `heap_dump.cr:96`, `thread_list_tripwire.cr:260`.
- [ ] R5 `heap_marked?(chunk, ordinal)` fast + `heap_marked_slow?(header)` for diagnostics
- [ ] R6 `collect.cr:1417` and `heap.cr:2121` use `ChunkHeader.data_start`, + spec
- [ ] R7 sweep block-walk extraction as its own no-behaviour-change commit FIRST

## Phase 1 — CLOSED

Gate was "flat", and flat is what the measurement supports. Note what that is
worth: the bitmap arm does strictly *more* work (union reads, allocate-black
still on the header, sweep still walking headers), so flat means the added cost
is under the noise floor. It licenses continuing; it is not a win.

## Phase 2 — O(1) chunk lookup — MECHANISM PROVEN, DEFAULT STAYS OFF

- [x] Two-level page-granular table; granules are **exact** (chunks are
      page-aligned AND page-multiple), so the `contains?` verify is defence in
      depth rather than part of the resolution
- [x] Entries live/die inside the same `@index_lock` sections as the sorted
      index; `chunk_containing`'s locking discipline unchanged
- [x] Chunks > 1024 granules not published; binary-search fallback
- [x] `find_block`'s 64-bit division gone (delegates to the reciprocal)
- [x] 13 targets x 3 configs all green
- [x] **phase_mark −6.6% / −17.7%**, p=0.016 / 0.0001, surviving sign test,
      Wilcoxon, ANCOVA and DiD. Pause −3–4%.
- [x] RSS +16–21% found, diagnosed as THP (2 MiB fault granularity, 160x the
      documented estimate), fixed with `MADV_NOHUGEPAGE` → +1.6%.
      `GCRY_RADIX_THP=1` kept for the TLB A/B.
- [ ] TLB A/B: does `MADV_NOHUGEPAGE` cost any of the mark win?
- [ ] Re-cut RSS at Kemal scale post-fix

### The finding that outranks the phase — ACTED ON

Kemal's **GC duty cycle is 0.2–0.5% of wall time**. An infinitely fast mark buys
**+0.15pp** on `/json`. The plan's +5–10pp (Phase 2+4) throughput expectations
are unreachable by any mark-side work, at any sample size.

Resolved by doing both of the recommended options:

- [x] **Gates restated on the axis each phase moves** (plan §Verification):
      Phase 2/4 on `phase_mark` + pause; Phase 3 on `phase_sweep` *and* ns/alloc;
      Phase 6 on ns/alloc. Kemal keeps the regression-guard and % of Boehm jobs
      and loses the judging job for mark-side phases.
- [x] **A GC-bound workload stood up**: `bench/micro/gc_phases.cr` /
      `make bench-gc-phases`, 9–41% duty cycle depending on survival rate,
      `phase_mark` 3.0–16.0 ms per collection against Kemal's ~230 µs.
- [ ] Radix A/B on it — first end-to-end evidence the mark work pays (in flight)
- [ ] THP A/B: does `MADV_NOHUGEPAGE` cost the mark win? (in flight)

Phases 3 and 6 keep a real end-to-end throughput claim: they touch every
allocation, which is where the mutator's time actually goes, and is why the
2026-08-01 alloc-bitmap reject was a *throughput* reject.
## Phase 3 — occ + bitmap sweep + pool allocation — CORE LANDED, INCOMPLETE

Behind its own knob `GCRY_BITMAP_ALLOC=1` (implies `GCRY_BITMAP`), so the
mark-only representation that Phase 1 gated and measured stays exactly as it
shipped while this is built out.

- [x] Pool cursor `{chunk, word, free_mask, word_base}` per size class;
      fast path is tzcnt / blsr / one atomic occ store. **No chunk lookup.**
- [x] `occ` set on alloc, cleared on free — both atomic (64 blocks share a word)
- [x] Bitmap sweep: `Kernels.sweep_words` streams `occ &= mark`, popcounts give
      all four numbers the policy needs, and clears `mark` in the same pass
- [x] The Phase 1 union retires under this knob, and only under it
- [x] `@freelist_clean` forced false on this path — a stale `true` would hand
      out dirty memory that Crystal assumes is zeroed. Verified: 0 dirty bytes.
- [x] Old generation only; nursery chunks keep headers (Phase 8)

### Defects found by the gates and fixed (all verified red -> green)

- [x] **Allocate-black was skipped**, so every block allocated in the post-STW
      window had `occ=1, mark=0` and `occ &= mark` reclaimed it *while live*.
      `GCRY_DISABLE_LAZY_SWEEP=1` flipped it 3/3, which named it.
- [x] **`bitmap_reset_pools` raced mutators** — nulled `@pool_chunk` between
      the mask read and the chunk read, `signal 11 at 0x1c`, 4/4 deterministic.
      Removed; cursors drop per chunk under the lock sweep already holds.
- [x] **`GCRY_POISON_FREED` was armed and inert** for small blocks. The bitmap
      free path now poisons, and the sweep stands down to the header walk when
      the knob is on — per-block work needs a per-block pass.
- [x] **Stale USED headers resurrected reclaimed blocks into `occ`** via
      `find_object` -> mark -> `occ = mark`. `occ` is now the authority
      (`block_allocated?`), in `find_object`, `mark_impl` and the invariant.
- [x] **TLAB bypassed the allocator entirely** (`allocate` dispatches to it
      first), so `occ` was never set and the sweep reclaimed everything live.
- [x] **Blacklisted pages were handed out**; now masked per word, same counter.
- [x] **`alloc_batch` was NOT inert by construction** — `bitmap_alloc=` forces
      tlab off, which *opens* that gate. Closed explicitly.
- [x] **Explicit free left `mark` set**, so `occ = mark` resurrected freed
      blocks. Free clears both bits.
- [x] Atomic counters implied by `bitmap_alloc` (batched `live_objects_sub`
      loses a whole chunk's worth on the non-atomic path)
- [x] Two bench walkers (`property_test`, `mt_property_test`) had the same
      stale-header bug `invariant.cr` was already fixed for
- [x] `mt_property_test`'s `(reported - walked).to_i64` underflowed on UInt64

### Third instance of a new mechanism disarming an existing gate

`heap-counters`' control sets `GCRY_HEAP_COUNTERS_ATOMIC=0` to show the plain
path loses increments — but `bitmap_alloc` implies atomic, so the plain path
never ran and `lost 0` where a loss is required. The gate refused to certify.
Control arm now pins `GCRY_BITMAP_ALLOC=0`; loses 1967 again.

(Previously: the radix disarmed `find-block-race`'s control.)

### OPEN: an unresolved corruption under concurrent stress

Two symptoms, almost certainly one root cause, and **this is the blocker for
Phase 3**:

1. `mt-property-test-short`: `live_objects mismatch reported=98 walked=233`,
   a consistent ~135 gap under concurrent mutators.
2. `page-release-corruption`: the HOLED arm faults **1-3 of 4** where the
   default arm is clean **3 of 3** (8.6-8.9 MB released, 0 faults). So it is
   this representation's, not that arm's documented flakiness.

Ruled out so far, each by a measurement rather than by reasoning:

- Mark left set on explicit free (fixed; symptom persists)
- Counter atomicity (forced atomic; symptom persists)
- Free-page release: the entire path was stood down for bitmap chunks —
  `unlinked 0`, no madvise — and the fault **persisted at 1-3 of 4**. An
  `occ`-built live mask made the walk engage (0 B -> 1.97 MB) and corrupt;
  declining only the madvise made it *worse* (3 of 4) because the freelist
  unlink still ran. Page release is not the cause.

What that leaves: something in the allocator/sweep pair that only shows with
concurrent mutators. The streaming sweep read-modify-writes a whole `occ` word
while other threads allocate into it; the size-class lock is supposed to
serialise that, and the next step is to verify it actually does on every path
into `bitmap_alloc_locked` — including `bitmap_take_pool_chunk`'s `map_chunk`,
which takes `@chunk_list_lock` and not the class lock.

### Also owed

- [ ] Free-page release is **not ported** and explicitly declines on bitmap
      chunks (`set_holed` / `set_sparse` skipped). Costs RSS on those chunks.
      `page-release-corruption`'s arms now pin `GCRY_BITMAP_ALLOC=0` so the gate
      tests the header-representation walk it is about.
- [ ] Dormant-flush overshoot fixed (`finish = base + mapped_bytes` overshot by
      `data_offset`; now `chunk.address + mapped_bytes`).
- [ ] `bitmap_take_pool_chunk` walks the chunk list — O(chunks) per exhausted
      chunk. Wants a per-class pool list, ascending address order.
- [ ] Nursery chunks still header-based (Phase 8)
- [ ] No measurement yet: sweep and alloc claims both unmeasured

### phase_mark win (both representations, not gated)

Two changes in the shared mark path, additive, verified paired n=24 with a flat
null control:
- **`clamped_scan_size` skips the per-object `chunk_containing` for small
  blocks** — `header.value.size` is the allocator-set class payload and a
  block reaching scan is marked+allocated, so the lookup's defensive clamp
  guarded a value that cannot occur. Carries most of it: −7.7% (bitmap), −5.5%
  (header).
- **Mark-loop prefetch ring** (`GCRY_PREFETCH`, default on): fixed-depth
  software pipeline, LIFO stack underneath so depth stays bounded. Adds ~2.7pp.
- Combined: **phase_mark −11.1%** (t=−4.92, CI [−1624,−685]) on the bitmap
  path, **−8.2%** on the default header path. null: −0.70%, flat.
- mark-audit / property / mt-property / stw-mt / invariants all green — the
  size-trust change does not under-scan.
- [ ] `bitmap_take_pool_chunk` walks the chunk list — O(chunks) per exhausted
      chunk. Wants a per-class pool list, ascending address order.
- [ ] Nursery chunks still header-based (Phase 8)
- [ ] No measurement yet: sweep and alloc claims both unmeasured

### phase_mark win (both representations, not gated)

Two changes in the shared mark path, additive, verified paired n=24 with a flat
null control:
- **`clamped_scan_size` skips the per-object `chunk_containing` for small
  blocks** — `header.value.size` is the allocator-set class payload and a
  block reaching scan is marked+allocated, so the lookup's defensive clamp
  guarded a value that cannot occur. Carries most of it: −7.7% (bitmap), −5.5%
  (header).
- **Mark-loop prefetch ring** (`GCRY_PREFETCH`, default on): fixed-depth
  software pipeline, LIFO stack underneath so depth stays bounded. Adds ~2.7pp.
- Combined: **phase_mark −11.1%** (t=−4.92, CI [−1624,−685]) on the bitmap
  path, **−8.2%** on the default header path. null: −0.70%, flat.
- mark-audit / property / mt-property / stw-mt / invariants all green — the
  size-trust change does not under-scan.

- [ ] R4 free mask = `~occ & tail_mask & resident_page_mask` (HOLED pages must not
      be handed out — refaults pages just released, regresses RSS)
## Phase 4 — mark loop prefetch + SIMD pre-filter

- [ ] R8 edges = `BlockHeader.user_from(header)`; 2-word `{user, chunk}` entries;
      `MarkStack::INITIAL_BYTES` 256 KiB → 512 KiB; prefetch i+32 but KEEP LIFO pop
      (BFS depth + `grow`'s raise = the allocating-raise deadlock)
## Phase 5 — packet parallel mark
## Phase 6 — allocation tuning
## Phase 7 — headerless (`-Dgcry_headerless`)
## Phase 8 — opt-in extras

## Review

(filled in per phase; numbers go to `bench/log/linux/<date>-simdgc-phase-N/FINDINGS.md`)


## Phase 3 — MEASURED, decisive win (bafc06c)

- [x] phase_sweep **−99.6%** (8320µs → 32µs, t=−99, 20/20) — "sweep → ~0"
- [x] ns_per_alloc **−27.8%** (t=−69, 20/20) — the metric 2026-08-01 *regressed*;
      vindicates occ-replaces-freelist
- [x] All Phase 3 correctness gates green under GCRY_BITMAP_ALLOC=1

## Phase 4 — prefetch done, range_filter deferred

- [x] Mark-loop prefetch ring + `clamped_scan_size` lookup removal:
      phase_mark **−8% (header) / −11% (bitmap)**, both representations (778b956)
- [ ] SIMD `range_filter` prefilter — DEFERRED. Low value on measurable
      workloads: stack scan is <1% of mark time here, and the heap conservative
      prefilter rarely skips a whole object (objects have live pointers). The
      plan itself said "measure before wiring; does not pay on pointer-dense."

## Phase 5 — foundation safe, sharding is the remaining lever

- [x] Lock narrowed off the per-word acceptance path (daf0b58): 8-worker
      phase_mark 503ms → 137ms, correctness-gated. Still net-worse than serial
      (8ms) — the single shared stack's per-object push/pop lock is the residue.
- [x] **Per-worker sharded stacks** — thread-local worker slot, per-worker
      mmap'd push buffers (raw StaticArray storage, no managed alloc), batched
      flush/pop against the shared stack, termination proven safe (a worker only
      goes busy by popping a non-empty batch, so busy==0 && empty is stable).
      Validated: stw-mt-property-test 3/3, mark-audit, parallel-mark-process,
      mt-property all green.
- [x] Worker drop-out bug fixed: workers stay in the cycle on `@mark_parallel`
      and treat a transient empty as a pause, not an exit.
- [x] Result: **2 workers −14.8% vs serial** (t=−13.98, 14/14), a real win
      where it was 60x-worse before.
- [ ] **Scales only to 2 workers**; 4+ regresses. Not lock contention (~2000
      batch-lock ops) and not the chunk cache (radix on doesn't change it) —
      it is the per-object **shared statistics counters** in scan_object /
      mark_impl (`@layout_conservative_scans`, `@type_id_*_rejects`), which every
      worker increments on the same Heap fields → false sharing. Needs
      per-worker counters summed at end. That is the ceiling to break next.
- [ ] Helpers still busy-spin between collections (separate, pre-existing).

## Decision point for the next step

Three candidates, materially different risk/reward:

1. **Parallel-mark sharding** (Phase 5 finish): measurable here, dominant phase,
   but a concurrent-marker rewrite = highest UAF risk, and the payoff is an
   experimental off-by-default knob.
2. **Kemal ns_per_alloc cut**: the −27.8% alloc win is the *one* axis that
   touches the mutator hot path rather than the GC pause, so it is the only
   thing here with a credible path to end-to-end Kemal throughput — the plan's
   actual goal. Needs the bitmap allocator hardened for sustained HTTP
   concurrency first (its bugs were fixed 4 commits ago).
3. **Phase 7 headerless**: targets RSS × Boehm ≤ 1.0, the shipping bar. Biggest
   strategic value, biggest effort (port every diagnostic behind -Dgcry_headerless).## Phase 6 — allocation tuning — SHIPPING CONTENT DONE

- [x] `prefetchw` ahead of the bitmap alloc cursor (`GCRY_ALLOC_PFW`, default
      2 KiB): −2.3% ns_per_alloc (t=−3.86, 14/16). Modest here (steady-state
      reuse, not fresh memory); helps the fresh-chunk case simdgc measured at
      7.1→4.2 ns.
- [x] Pool lists already ascending-address order (bitmap_take_pool_chunk takes
      the lowest-address chunk with capacity).
- [x] alloc_batch closed under bitmap_alloc; tight_grow/prefer_freelists are
      freelist-shaped and unreachable — the no-op-knob retirement the plan asks.
- [x] live_objects/free_bytes already come from sweep popcounts (Phase 3).
- [ ] **Per-thread TLAB cursors — deferred, EC4-only.** On EC1 (what Kemal
      ships) the size-class lock is uncontended, so per-thread cursors give ~0;
      the win is EC4+ multi-mutator. Deferring keeps concurrency risk off the
      recently-hardened allocator. The shipping allocator win (−27.8% ns/alloc)
      is already banked from Phase 3. Design: thread-local per-class cursor,
      refill hands out a whole 64-block word per lock (simdgc3 gc_tpool).## Phase 8 — opt-in extras — partly done, one honest miss

- [x] **AVX-512 variants where the IR shows `vpopcntq`** — done in Phase 0 and
      re-verified: tier detected `avx512` on this host, sweep kernel
      **176.8 GB/s L2** vs 64.4 AVX2 vs 11.7 scalar (2.7x over AVX2). Converges
      at DRAM (30.3 vs 30.0), but chunk bitmaps are ~1 KiB and live in L1/L2,
      which is where the win is.
- [ ] **Hugepages — MISS, and structurally so.** `GCRY_HUGEPAGES=1` implemented
      and measured: +0.5% mark, +0.2% alloc, RSS n.s. Nothing on any axis
      against a predicted −20% mark. Cause: chunks are 128 KiB separate mmaps
      and THP needs ≥2 MiB inside one VMA, so the advice can never be honoured.
      "Reserved arena + MADV_HUGEPAGE" is one prerequisite plus one mechanism,
      not two options. The arena is a chunk-allocator restructure — the real
      work, still to do. Knob ships off, documented as a no-op.
      FINDINGS: bench/log/linux/2026-09-03-simdgc-hugepages/
- [ ] Nursery minors on bitmaps — deferred; needs the nursery moved onto the
      bitmap representation (a Phase 3 extension), not just kernel reuse.

## Phase 7 — headerless — IMPLEMENTED on branch `simdgc-headerless`

Tracked in `tasks/phase7-headerless.md` (7.1–7.8, review findings, soak).
The blast-radius note below is kept as the record of why it got its own branch.

## Phase 7 — original assessment (2026-09-03), superseded

Blast radius measured before starting, which is why it was not started:
**207 BlockHeader field reads, 97 from_user/user_from, 154 header.value reads,
36 BlockHeader::SIZE arithmetic sites, across 22 files** — plus porting six
diagnostics (poison_holders, invariant, mark_audit, address_space_audit,
heap_dump, segv_report) with their purpose-broken gates re-run and observed red.

This is a multi-session epic in a *conservative* collector, where a missed site
is not a failing test but a use-after-free that surfaces days later under load
(the open `String#empty?` hunt is exactly that shape). Landing a partial
headerless rewrite on a shared branch would be the single riskiest thing done to
this codebase. It wants its own branch, its own staging, and its own soak — not
the tail of a long session.

It remains the right next big lever: 16 B/object is 50% of a class-0 block, and
it is the phase aimed at RSS x Boehm < 1.0, which is the shipping bar.

## Pre-review pass (2026-09-04): reviewer's shoes

- [x] Run the rest of the plan's verification list: asan, invariants,
      spec-process, stw-index-race, poison-freed, oom-no-hang, stw-watchdog,
      soak-smoke (both builds). Fix what reproduces.
- [x] Adversarial review of ddafb55 + the headerless core paths; every
      reported bug must come with a reproduction.
- [x] Smell: the collect scrub inflates `clear_stack_calls`, a metric that
      meant the allocation-time wipe. Give it its own counters and put the
      stack_scrub spec back to its original meaning.
- [x] Smell: `on_thread_stack` in `clear_stack_body` now means "bounds known".
- [x] Specs: turn guards into coverage where the property survives the
      representation (freelist reuse -> block reuse; TLAB examples keep their
      allocation checks; headerless-only examples for the refused switches:
      nursery, bitmap_marks/alloc off).
- [x] Re-run spec suite x3, gates touched, commit, push.
- [x] Found on the way: large-object scan length was the mapping extent
      (fixed, spec/large_scan_bounds_spec.cr); live attribution bytes were
      zero under headerless (fixed).
- [x] Adversarial review subagent re-run after the rate limit reset: four
      reproduced bugs (large free/double free, large atomic scanned, realloc
      atomicity, bitmap chunks freelist-linked from the bounded-excess
      branch) and one argued race (revive during the dormant flush), all
      fixed and pinned. FINDINGS Update 12.
- [x] (resolved above) pre-existing on master: `make dormant-flush-race` queued arm loses a
      live large block about once per 6-18 children (sweep frees it; header
      FREE; chunk queued for release). ~4x more frequent on this branch
      because collections are 2x faster. FINDINGS Update 12 has the numbers
      and what was excluded.


## Fully green before the PR (2026-09-04)

- [x] `make live-graph-audit`: the 4x floor measured the dormant flush; the
      gate now reads each walk's own counter. That exposed the HOLED walk's
      real race (TLAB-held blocks zeroed after hand-out); fixed by running the
      walks under every small-allocation lock. Green 5 of 5; corruption gate
      3 of 3. FINDINGS Update 13.
- [x] `make dormant-flush-race`: found the lost root (worker stopped inside
      alloc_large holding only interior pointers); in-flight root + CAS mark.
      0 of 72 children at 8 workers. FINDINGS Update 14. Original plan: Instrument: tag each
      large block with the collection number at allocation; on refusal print
      the worker's round, the tag, and the sweep path that freed it (STW
      sweep vs after-world lazy sweep; which thread). Candidate windows:
      thread-birth registration (worker not yet in the STW list while its
      block is live), after-world sweep vs allocation, register capture.
      Green 5 runs in a row at 8 workers.

## Close the gap to Boehm (2026-09-04)

Headerless Kemal /json is 92.3% of Boehm; the collector is 0.2-0.5% of wall
time, so the gap is the mutator's allocation path.
- [x] Profile the headerless Kemal server under wrk (perf if the kernel has
      it; otherwise an allocation microbenchmark per mode vs Boehm).
- [x] Remove per-allocation atomics from the bitmap fast path: per-thread pool
      cursor (lock only at refill), batched bytes_since_gc.
- [x] Trim the GC.malloc entry (dedicated hit path) (checks, hooks, rounding) to what a hit needs.
- [ ] Paired Kemal n>=7 per change; keep only measurable wins; gates; update
      the PR table.
- [x] The real gap: page faults from releasing emptied chunks every cycle;
      warm retention up to the threshold by default. 112.7% of Boehm.
- [x] RSS under load (44.5 MB vs Boehm 22 MB): the fixed 32 MiB threshold and
      warm budget. Adaptive threshold = live × factor (clamped 8–64 MiB),
      warm budget follows; `GCRY_THRESHOLD_FACTOR`; spec
      `spec/adaptive_threshold_spec.cr`. Measure k = 50/100/200 vs Boehm.
- [x] Gates on the final tree, squash, push, open the PR (#34).
- [x] CI red on `thread-birth-root`: SYSMON check read `arg` as a Thread;
      fixed with a live-block + type-id test; regression spec
      `process_spec/regression/5_pthread_create_raw_arg_spec.cr`.
- [x] Multi-mutator coverage through the process GC:
      `process_spec/regression/6_multi_mutator_alloc_spec.cr`.
- [ ] Run the full CI `test` job list locally (23 targets) before pushing.
- [x] `make scheduler-roots` hung under load (1 in 22 contended runs; upstream
      0 in 101): SYSMON allocates its main Fiber in `Thread#start`, and the
      exemption let two threads pop one freelist head — its fiber pushed twice
      onto `Fiber.fibers`, `next` = itself, root scan looping. Exemption
      withdrawn; `7_sysmon_alloc_race_spec.cr` reproduces it (4 892–8 518
      shared blocks per 200 000); 60/60 clean after.

## Multi-thread allocation: per-thread pool cursors (plan)

The single-mutator regime is a global flag; it is sound only while exactly
one thread allocates, so under execution contexts it ends at boot. Real
multi-thread support means each thread owns its cursor, and the regime goes
away:

- [x] `CursorSet` per thread (`LibC.malloc`, thread-local cache of integers
      — pointer initialisers go through `__crystal_once`, which allocates);
      per slot `chunk / word / free_mask / word_base / occ_word / in_flight`;
      monotonic per-set byte/object counters credited by delta.
- [x] `fast_alloc` on the thread's set: sentinel in `in_flight` first (a
      stop-the-world that finds it pins the set), re-read the mask, atomic
      `occ` OR (a `free` on another thread shares the word), local counters.
      Off while `@lazy_sweep_pending`, `@collecting`, or on the fallback set.
- [x] Chunk `CURSOR` flag: taken under the class lock at refill, skipped by
      other refills; `PINNED` for chunks held across a stop-the-world by a
      mid-allocation set — the after-world sweep skips them, the next
      stop-the-world zeroes their marks.
- [x] `bitmap_settle_cursor_sets` at every stop-the-world: credit, retire
      idle sets, pin mid-allocation ones, free sets whose thread exited
      (pthread key destructor marks them). Table of 64 + a shared fallback
      under the class lock; `cursor_set` never raises (a raise under the
      class lock allocates on the same lock — that hung `process_spec` at the
      65th thread).
- [x] `with_freelist_lock` lock-skipping deleted; `single_mutator` gone;
      `GCRY_ALLOC_FAST_PATH=0` replaces `GCRY_SINGLE_MUTATOR=0`.
- [x] Gates green on the tree (30 targets, 12 spec configurations);
      scheduler-roots ×40 contended clean.
- [ ] Kemal vs Boehm re-measured; FINDINGS + PR updated; then the full soak.
- [ ] Execution-context throughput: the stop-the-world pause is 14–27 ms per
      collection at 4 threads with mark and sweep in microseconds — whole
      thread-stack scans. Measure `scan_other_thread_stacks` and the SP
      snapshot on this box; low-water skip.
- [ ] `bitmap_take_pool_chunk` walks every chunk of the class per refill:
      O(chunks) at large heaps (1 125 ns/alloc at 960 MB). Per-class pool
      list of chunks with capacity, ascending address order.
- [ ] Full soak once the above is in.
