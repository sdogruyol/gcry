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

### Known gaps — this knob is NOT safe to enable generally

- [ ] **The bitmap sweep never writes FREE into reclaimed headers.** So
      `BlockHeader.free?` reads USED for reclaimed blocks, which
      `find_object`, the invariants, poison and `@finalizers.notice_reclaim`
      all consult. **Finalizers do not run for bitmap-reclaimed objects.**
- [ ] `GCRY_BITMAP_ALLOC=1` crashes the full spec suite (heaps default the
      nursery on, plus the gap above). Only the dedicated spec configuration —
      `bitmap_alloc = true`, `nursery_enabled = false` — is supported.
- [ ] Blacklisted and MADV_DONTNEED'd pages are not yet masked out of the free
      mask; `chunk_free_mask` applies the tail mask only
- [ ] `bitmap_take_pool_chunk` walks the chunk list to find capacity — O(chunks)
      per exhausted chunk. Fine at 466 chunks, wants a per-class pool list
      (ascending address order — the descending list cost simdgc3 25%)
- [ ] Dormant/unmap must call `bitmap_drop_pool_chunk` (written, not wired)
- [ ] No measurement yet: the sweep and alloc claims are both unmeasured

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
