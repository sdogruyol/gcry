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

- [ ] `ChunkHeader` gains `data_offset : UInt32` (SIZE 24 → 32)
- [ ] Assert `chunk_data_offset[class] < Platform.host_page_size` at init
- [ ] Magic reciprocal per class + exhaustive spec vs `//`
- [ ] `heap_marked?` / `set` / `clear` on the chunk bitmap
- [ ] Large chunks: one bit in flags, `data_offset` stays 24
- [ ] Delete `mark_bitmap.cr` and `-Dgcry_side_bitmap`
- [ ] NO `occ`, NO allocator change in this phase
- [ ] Gate: Kemal `/json` flat, RSS flat

### Phase 1 hard requirements (from design review)

- [ ] R1 `heap_set_mark` uses atomic OR (relaxed) + skip-if-set load. Ships ON.
- [ ] R2 no per-bit clear; marks consumed wholesale per chunk
- [ ] R3 `barrier.cr:222` routed through `heap_set_mark`; static `BlockHeader` mark
      API deleted in the bitmap build (compile error, not wrong answer). Same for
      `heap_dump.cr:96`, `thread_list_tripwire.cr:260`.
- [ ] R5 `heap_marked?(chunk, ordinal)` fast + `heap_marked_slow?(header)` for diagnostics
- [ ] R6 `collect.cr:1417` and `heap.cr:2121` use `ChunkHeader.data_start`, + spec
- [ ] R7 sweep block-walk extraction as its own no-behaviour-change commit FIRST

## Phase 2 — O(1) chunk lookup

- [ ] Radix lock-free iff `@world_stopped`, `@index_lock` otherwise (today's rule)
- [ ] Granule = `Platform.host_page_size` (64 KiB straddles → ~25% fallback)
- [ ] Large chunk spanning > 1024 granules: not inserted, falls back to binary search
## Phase 3 — occ + bitmap sweep + pool allocation (together)

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
