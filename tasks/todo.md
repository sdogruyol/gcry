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
- [x] aarch64 IR gate — `make kernels-ir`, and "no local arm64 host" was a
      misreading: `--cross-compile --emit llvm-ir` runs the pipeline for a
      target and stops before linking, so the check needs that target's
      compiler and never its CPU. Both arches asserted from one host, ~19 s:
      aarch64 `+neon`, `+sve`, `llvm.ctpop.v2i64`, `<2 x i64>`, `whilelo`,
      `cnt z`; x86_64 `vpandn`, `vpshufb`, `llvm.ctpop.v4i64`,
      `llvm.ctpop.v8i64`, `<4 x i64>`, `<8 x i64>`. Each arch also rejects the
      other's fingerprints, since a grep for a string a file never contains
      reads like a grep for one it should contain and does not — and that half
      earned itself immediately: `<2 x i64>` as an "aarch64 only" pattern is
      SSE2's type as well, and the run said `PRESENT` rather than passing.
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
- [x] Spec: same workload under both representations, same live set —
      `spec/bitmap_marks_spec.cr`, now three-way on the header layout (header /
      marks-only / bitmap): same chain walked, same payload checksums, same
      `live_objects`, and a failure names the arm that drifted. Observed red by
      taking the block ordinal off `chunk + ChunkHeader::SIZE` instead of
      `data_start`: `marks-only: live_objects 0, header 200`.
- [x] Run every gate under `GCRY_BITMAP=1` — `make bitmap-marks-freelist`
      (~36 s, in CI). The arm nothing was running: marks in the chunk while the
      *freelist* allocator keeps handing out header-carrying blocks. It needs
      `GCRY_BITMAP_ALLOC=0` too under `-Dgc_none`, because the process GC
      defaults the pool allocator on and `GCRY_BITMAP=1` alone there is the arm
      CI already had. Unit specs 299, process specs 32, property 50 000
      iterations, MT 2/4 workers, STW+TLAB+nursery, pattern fuzz — plus, run
      once by hand at full length, property 100 000, MT 2/4/8, pattern fuzz 200
      phases, thread storm, stress and json_churn samples, and
      `GCRY_DEBUG_INVARIANTS=1`. All green on first run; no defect found.
- [x] NO `occ`, NO allocator change in this phase
- [x] Gate: Kemal `/json` flat, RSS flat — answered, and by a larger measurement
      than this line asked for. `bench/baseline/perf_smoke.json` records 48 green
      headerless runs (2026-09-14): `pct_json` 100.45 of Boehm, `rss_x` 0.9495,
      `pause_p50_ms` 0.6361, and `perf smoke` has gated every run against it
      since 2026-09-13 — 59 jobs, 0 failures. Marked read 2026-09-23; it had said
      "in flight" since the phase closed.

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
- [x] Latent sibling, now fixed: the dormant flush computed
      `finish = data_start + mapped_bytes`, overshooting the chunk end by
      `data_offset` and correct only because `end_page` rounded back down over
      a sub-page offset. `flush_pending_dormant_chunks` takes
      `chunk.address + mapped_bytes` now, with the reasoning at the line.

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

Checked against the tree on 2026-09-23, not from memory — the boxes had sat
unticked under a section headed "Phase 1 — CLOSED" since the phase closed,
which is the shape of a record nobody re-reads.

- [x] R1 `heap_set_mark` uses atomic OR (relaxed) + skip-if-set load. Ships ON.
      `chunk_set_mark` (`heap.cr`): `return if (word.value & bit) != 0`, then
      `atomicrmw Or … Monotonic`.
- [x] R2 no per-bit clear; marks consumed wholesale per chunk. The streaming
      sweep publishes `occ[i] = mark[i]` and zeroes by **word**
      (`sweep_words`, `bitmap_alloc.cr:464` / `:987`); no path clears one bit.
- [x] R3 `barrier.cr` routed through `heap_set_mark` (`barrier.cr:231`).
      **Half of this one did not land as written**: the static `BlockHeader`
      mark API is not deleted in the bitmap build, so a misuse is still a wrong
      answer rather than a compile error. It is *reachable on purpose* now —
      `collect_sweep.cr:1084` reads it for a non-bitmap chunk, and the
      header layout is a supported build — so the deletion is not a leftover
      task but a requirement the design outgrew. `heap_dump.cr` and
      `thread_list_tripwire.cr` no longer touch it at all.
- [x] R5 a fast bitmap reader and a header reader, reached differently than
      specified: one `heap_marked?(header)` dispatches (`@bitmap_marks` →
      `chunk_marked?(chunk, ordinal)`, else `hdr_marked?`) instead of two named
      entry points. The diagnostic split the requirement asked for is what
      `chunk_marked?` / `hdr_marked?` are.
- [x] R6 `collect.cr` and `heap.cr` use `ChunkHeader.data_start`
      (`collect.cr:1429`, `:1985`, `heap.cr:1878`), with
      `spec/chunk_layout_spec.cr` and `spec/block_payload_spec.cr` pinning it.
- [x] R7 sweep block-walk extraction first — a sequencing requirement for work
      that is long since merged; nothing in the tree can confirm or deny it now,
      and it is ticked as spent rather than met.

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
- [x] TLB A/B: does `MADV_NOHUGEPAGE` cost any of the mark win? **No** —
      pause per collection −1.40% with huge pages (t=−1.30, noise), RSS +3.27%
      (t=+12.45), on a 78%-GC workload, n=12 interleaved (2026-09-23). It could
      not be run before that day: the knob only skipped `MADV_NOHUGEPAGE`, which
      under THP `madvise` gives 0 kB of huge pages either way.
      `bench/log/linux/2026-09-23-radix-thp-ab/FINDINGS.md`
- [x] Re-cut RSS at Kemal scale post-fix — `perf smoke` does it on every run
      against Kemal, and the 48-run headerless baseline (2026-09-14, after the
      `MADV_NOHUGEPAGE` fix) records `rss_x` **0.9495** of Boehm, gated since.
      Marked read 2026-09-23.

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
- [x] Radix A/B on it — first end-to-end evidence the mark work pays. **It
      does, in proportion to edges** (2026-09-23): graph-heavy (`--fanout=6
      --shuffle`) pause per collection −65.1%, `ns_per_alloc` −59.2% end to end;
      edge-free (`--fanout=0`) −2.1%, not significant — at the *same* 77% duty
      cycle. The win follows chunk lookups during mark, not GC time.
      `bench/log/linux/2026-09-23-radix-end-to-end/FINDINGS.md`
- [x] THP A/B: does `MADV_NOHUGEPAGE` cost the mark win? Same arm as the TLB A/B above — answered there: no.

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

### CLOSED 2026-09-14: the corruption under concurrent stress

Both symptoms were re-run on the current tree and neither reproduces. The
section is kept because "it stopped happening" is worth as much as the
original report only if the re-measurement is written down.

1. `mt-property-test`: **0 failures** at 500 iterations on 2, 4 and 8 workers
   (`collects=500 verifies=502 failures=0` per worker count), and the short
   arm is green in the CI `test` job. The `reported=98 walked=233` gap is
   gone; the counter fixes above (`occ` as the authority in `find_object` /
   `mark_impl` / the invariant, atomic counters implied by `bitmap_alloc`,
   and the two bench walkers' own stale-header bug) are what it was.
2. `page-release-corruption`: **0 of 24 per arm across six runs** on the
   layout the walks exist on, with the HOLED arm unlinking 11 674-12 904 page
   runs and the mostly-empty arm releasing 60.3-68.7 MB. The 1-3 of 4 was the
   `occ`-built live mask experiment, which was withdrawn: the walks stand
   down on bitmap chunks and the arm that faulted no longer exists.

The next step this section named — "verify the size-class lock serialises the
streaming sweep's `occ` word against every path into `bitmap_alloc_locked`" —
was done on 2026-09-12 and the argument is at `sweep_words_poisoning`: cursor
sets are settled inside the stop, a frozen one keeps its chunks PINNED and
the walk skips them, an idle one is retired and its owner must re-enter
through the class lock the walk also takes; allocate-black keeps anything
handed out during `@collecting` in `mark`; and a bit in `mark` but not `occ`
cannot exist. Measured with `GCRY_SWEEP_OCC_AUDIT=1`: **0** dead words with a
cursor mid-allocation over 71 325 published words.
`bench/log/linux/2026-09-12-sweep-occ-publish/FINDINGS.md`

What did *not* survive that re-run is the gate itself, and it is fixed here:
`make page-release-corruption` built `-Dgc_none` alone since the headerless
default flip, where `GCRY_BITMAP_ALLOC=0` is ignored, so all three arms
reached nothing - `unlinked 0` in 4 of 4 runs. It builds
`-Dgcry_block_headers` now and the harness refuses to compile any other way.

### Also owed

- [ ] Free-page release is **not ported** and explicitly declines on bitmap
      chunks (`set_holed` / `set_sparse` skipped). Costs RSS on those chunks,
      and since the headerless flip that is *every* chunk on the default
      layout. `page-release-corruption`'s arms pin `GCRY_BITMAP_ALLOC=0`, and
      as of 2026-09-14 the gate is built `-Dgcry_block_headers` as well —
      without it the knob is ignored, all three arms release nothing, and the
      gate can only report that it never ran (`unlinked 0`, 4 of 4).
- [x] Dormant-flush overshoot fixed (`finish = base + mapped_bytes` overshot by
      `data_offset`; now `chunk.address + mapped_bytes`).
- [x] `bitmap_take_pool_chunk` walks the chunk list — measured 2026-09-13 and
      retired: the walk is per *capacity version*, not per exhausted chunk, and
      the count is 2.0 rebuilds per collection (one per active class slot)
      whether the class holds 29 chunks or 598. `make pool-refill-cost`.
- [ ] Nursery chunks still header-based (Phase 8)
- [x] Sweep and alloc claims, measured 2026-09-23 on the axes the gates were
      restated on (header build, threshold pinned so only the mechanism differs,
      90% garbage, n=10): `phase_sweep` **−99.4%** (7 236 → 41 µs, ~180x),
      `ns_per_alloc` **−46.6%** end to end, RSS −1.3%.
      `bench/log/linux/2026-09-23-bitmap-sweep-alloc/FINDINGS.md`

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

### Phase 3 requirement still open

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
      **2026-09-23: the counters were a third of it, and done.** On the current
      tree (graph-heavy `gc_phases`, 12 vCPUs) parallel mark is slower than
      serial at *every* count — +34.4% at 2 workers, +39.4% at 4 — not −14.8%.
      Per-worker, line-padded counters (summed on read; the shared ones were
      also *lossy* under concurrent `+=`) take that to **+20.4% / +28.1%**, the
      same as deleting the counters outright, at no cost to the serial path
      (−1.0%, t=−0.66). The rest is something else — candidates: atomic `OR`
      on shared mark words (true sharing on a shuffled graph), the batched
      steal, the helpers' spin — and nothing has separated them yet.
      **Then separated by object size** (same graph, 64 → 512 B): 2 workers
      +30.5% / +8.8% / −19.1% / −27.7%, 4 workers +30.0% / −0.3% / −26.7% /
      **−50.5%**. The cost is per object and loses to small ones — every object
      crosses the shared stack's lock twice (flush, pop) and the batch scan has
      no prefetch. **Both tried**: local-first drain (−4 pts at 64 B, t≈0.9 —
      rejected, not in the tree); batch prefetch (512 B 2w −28.9% → −33.6%,
      4w −46.4% → −52.5%; neutral at 64 B — kept). The 64 B gap (~+30%) is
      what remains, and the candidate that fits it is true sharing on the
      mark bitmap's words, which needs a representation arm, not a knob.
      `bench/log/linux/2026-09-23-parallel-mark-scaling/FINDINGS.md`
- [x] Helpers still busy-spin between collections — **a full core each, for the
      life of the process** (idle: 2/4/8 workers burned 101% / 301% / 703% of a
      core). Spin briefly, then 200 µs sleeps: 4.3% / 11.9% / 26.9%, and no
      measurable cost to mark where parallel mark pays (|t| < 1.5).
      `bench/log/linux/2026-09-23-mark-helper-idle/FINDINGS.md`

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
- [x] Run the full CI `test` job list locally before pushing — done again
      2026-09-14 on the current tree, and the job is 87 shell steps now, not
      the 23 this line was written for: **87 of 87 green in 13.6 min**, from
      `crystal tool format --check` through the `GCRY_SOUND=1` correctness
      suite. Two steps finish instantly and both are honest (the `GCRY_STRESS`
      stress sample at 100 rounds, and the perf comparator's selftest).
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
- [x] Kemal vs Boehm re-measured on a quiet box (104.7%, t = 1.63; withdrawn
      version 104.4%; realloc-without-roots 105.0% → reverted); FINDINGS +
      PR #34 updated; `soak-smoke` and `soft-soak-ec4-smoke` green.
- [x] (superseded, stopped for the evidence run) 24 h `make soak` started 2026-09-05 ~20:00 local; output in the
      session scratchpad `soak_full.out`, telemetry `/tmp/gcry-soak.log`.
- [ ] Execution-context throughput: the stop-the-world pause is 14–27 ms per
      collection at 4 threads with mark and sweep in microseconds — whole
      thread-stack scans. Measure `scan_other_thread_stacks` and the SP
      snapshot on this box; low-water skip.
- [x] `bitmap_take_pool_chunk` walks every chunk of the class per refill —
      **not what it does, measured 2026-09-13.** The walk builds a sorted index
      of candidate addresses once per capacity version, and each sweep bumps
      that version: 163 840 allocations produce **80 rebuilds, 2.0 per
      collection, identical at 29 / 57 / 165 / 598 chunks** in the class. The
      per-allocation cost does grow linearly with the chunk count (0.0142 ->
      0.292 chunk visits per allocation across a 20.6x growth) and that is the
      arithmetic of a constant rebuild rate, not a regression: one visit per
      chunk per slot is **0.391% of what the sweep walks in the same
      collection**, which visits every block of every chunk. The churn arm
      reads the same. So the item becomes a documented cost — refill indexing
      costs one chunk-list walk per active class slot per collection — and
      `make pool-refill-cost` fails if that ever exceeds one per slot, which is
      the only way it becomes the per-refill walk this said.
      If a workload ever makes 0.391% matter (many chunks per class, few blocks
      per chunk), the fix is the sweep handing the allocator the chunks with
      room; caching the walk cannot help, since the sweep invalidates the
      version it is keyed on.
      `bench/log/linux/2026-09-13-pool-refill-cost/FINDINGS.md`
- [x] Full soak: 24 h `make soak` running on the pushed tree (eb77356) from 21:08 local 2026-09-05, output `soak_full2.out` in the session scratchpad, telemetry `/tmp/gcry-soak.log`.

## Review of PR #34 (sdogruyol, 2026-09-05 07:35Z) — done

- [x] Blockers 1 and 2 (type-punned `arg`; SYSMON exemption): gone with the
      single-mutator regime; per-thread cursor sets instead.
- [x] Blocker 3: SYSMON's set is created with `no_hit_path` — it always
      takes `allocate` and its cooperative wait, and the settle never
      retires or credits it. In-flight sentinel, atomic `occ`, CAS-credited
      counters.
- [x] Blocker 4: `Invariant.after_malloc` / `Trace.after_malloc` run on the
      hit path; `refresh_fast_path` no longer closes it under invariants
      (249 examples run it).
- [x] Should-fixes: warm budget = min(threshold, max(live × factor, floor))
      after every major; adaptive threshold gated on the bitmap allocator;
      `collect_a_little` recomputes; Darwin floor 16 MiB; factor clamp
      10–1000; tight-grow `min_bsg` floor 8 MiB. Spec for the warm cap.
- [x] Evidence: `run_kemal_ab.sh` + `analyze_ab.py` + `trials.jsonl` in the
      log; paired, 95% CI, Boehm null control, n = 20, base = v0.22.0
      headerless under the guard. Upstream 89.5% [86.1, 92.9] at 1.88× RSS;
      policy alone 100.9% [96.8, 105.1] at 0.97×; with cursor sets 106.7%
      [102.2, 111.2].
- [x] Split declined by the author: one PR, updated in place by new commits
      (merge of v0.22.0, fixes, logs), never a force-push. The policy-only
      arm was measured on a local branch for the table.
- [x] All 43 CI-job commands green on the final tree; reply posted.


## PR #34 performance follow-through (2026-09-05–06)

Plan: [PERFORMANCE_PLAN_PR34.md](../docs/PERFORMANCE_PLAN_PR34.md).
All work stays in PR #34; preserve the reviewed head as the cumulative baseline.

- [x] Measurement infrastructure: maintained runners/analyzer, committed alloc_ns,
      stable graph churn, counter names, root sub-timers; seven Python checks.
- [x] Medium-buffer cursor dispatch and boundary/zeroing/process regressions.
      Atomic EC4 allocation cost −22.5%; HTTP result inconclusive.
- [x] Refill availability indexing, lifecycle/race coverage, scaling trials.
      Fixed STW index locking and capacity freed behind a retiring cursor;
      release/acquire publication. Final 960 MB cost −87.8%, 8 KiB EC4 −73.2%.
- [x] Header-retention factorial micro/application trials. Keep defaults unchanged:
      coupled peak RSS −40.2%, post-GC RSS +88.6%, throughput inconclusive.
- [x] Atomic-leaf enqueue skip; graph correctness and paired phase measurements.
      Atomic pause −34.2%; pointerful graph inconclusive.
- [x] Final application confirmation: +5.5% [−0.6, +11.6], inconclusive;
      60 error-free trials and exact collector/server source hash check.
- [x] Record findings, update plan, and run applicable integration gates.
      Delivery uses new commits on the existing PR head without a force-push.
- [x] Diagnose native ARM stress failure against the reviewed baseline; preserve
      the header reproducer and gate cursor regressions in both bitmap layouts.
- [x] Reproduce and fix header dormant accounting, revival zeroing and peer-refill
      clearing; restore the process stress in header mode.
- [x] Fix the stage-2 cursor-cache lifetime defect; replace the ineffective
      ASan flag with actual instrumentation and a failing control.
- [ ] Header default decision: independent exclusive-host confirmation,
      burst/drop/recovery and native platform gates still required.
- [ ] Conditional root/controller/mark-stack work: deferred until workload gates open.

## Throughput at flat RSS: stage 2 plan (2026-09-06)

Evidence, this box, quiet (load 0.01), `bench/performance/kemal_ab.py`,
5 arms × 20 rotated rounds, Boehm null control 102.8% [97.8, 107.9]:
branch headerless 105.9% [101.2, 110.6] of Boehm at 1.03× peak RSS,
CPU 209 vs 240 ms/10k; master 88.1% at 1.69×. Main-thread PC profile under
wrk (5 000 samples, 2 ms): syscalls/libc ≈ 64–70% in both arms; gcry symbols
9.5% of main-thread time (Boehm: 8.7% in `GC_*` plus ≈ 9% in its allocation
lock/condvar symbols). So the GC is already about half of Boehm's cost and the
hard ceiling for further GC work is ≈ +10%; a realistic target is +4–6%
(≈ 110–112% of Boehm) with peak RSS unchanged. Where the 9.5% goes:

| main-thread share | what | counter evidence |
|---|---|---|
| 3.7% | `GC::realloc` 1.7 + `chunk_search_unlocked` 1.1 + `chunk_containing` 0.9 | String::Builder growth in JSON building; `realloc` binary-searches the index and allocates through the locked `allocate` |
| 3.0% | `alloc_old_small_locked` 1.8 + `allocate` 1.2 | 10% of allocations take the locked path (4.49 M of 44 M per 15 s); 705 k refills, only 29 k chunk advances |
| 2.4% | `malloc` / `malloc_atomic` wrappers (fast path inlined) | 34.8 ns per 48 B alloc vs Boehm 131 ns |
| ≈ 1% | mark, collection body, sweep | 17 majors/s, pause p50 1.18 ms: stop 0.28, roots 0.29, static 0.20, mark 0.40 |

Two rounds of twenty lost ≈ 8% each to a dormant-release storm (74–125 MB
`unmapped_bytes` in 15 s against 0–4 MB elsewhere): fully-free bytes sit at
the warm budget's edge and oscillate across it.

Every item is measured with the committed runner (20 rounds, null arm) and a
re-sampled profile; peak RSS × Boehm must not move.

- [x] 1. `realloc` without the lock (`c41a5e5`: 105.0% [97.4, 112.5], CPU 202 → 192 ms/10k). Take `fresh` through `fast_alloc` before
      `allocate` (it currently always uses the locked path); resolve the old
      block's chunk O(1) — the argument that makes the radix safe here is that
      a pointer being realloc'd or freed is owned and live, so its chunk cannot
      be unmapped under the reader; verify containment from the table entry,
      not the chunk. Re-measure the `add_root`/`delete_root` pair afterwards
      (was noise at +0.3%). Gate: realloc+lookup share < 1%; realloc specs,
      process specs 6–8, `stw-mt-property-test`, `find-block-race`. Expect +2–3%.
- [x] 2. Locked-path census, then fix the dominant cause (`80a0cf3`: 106.4% [97.7, 115.1], CPU 207 → 195). Per-reason counters
      on the slow path (realloc, refill, size > 32 KiB, `@collecting`, empty
      mask, no set) in `/gc-stats`. Word advances inside a CURSOR-held chunk
      need no class lock (the chunk is exclusively held); today 96% of refills
      are such advances. Expect +1–2%.
- [x] 3. Warm-retain hysteresis (`431b194`, one cycle of grace; measured with 4 and 5). Shrink the warm budget only after N
      consecutive majors below it and revive warm chunks before dormant ones;
      count `bitmap_dormant_revives` per trial. Gate: no trial with
      `unmapped_bytes` > 8 MB in a 15 s window; p99 down. Expect +0.5–1% mean,
      peak RSS unchanged (budget still capped by the threshold).
- [x] 4. Fast-path trims (`db81c73`: one TLS word, inlined hook shells; 34.8 → 31 ns). Plain occupancy store measured at 1–2 ns and declined: plain store
      for the occupancy bit while the chunk is CURSOR-held (cross-thread `free`
      into a held chunk must then take the cursor's slot, not the word);
      inline zeroing for payloads ≤ 64 B instead of memset; check the
      `GC.malloc` → `Gcry.malloc` → `Heap#malloc` → `fast_alloc` chain inlines
      to one frame. Expect +0.5–1.5%.
- [x] 5. Fixed cost per collection: the initial thread's `pthread_getattr_np` (106 µs, `/proc/self/maps`) cached (`8bdddb5`); the static-root skip declined at ≈ 0.3% of wall:
      static roots (495 KB every major) via soft-dirty skip of unchanged
      pages, and the 0.28 ms suspend/ack. Lowest priority: ≤ +1% and the
      static-root cache needs its own red arm.
- [x] Not in scope: the 64% of main-thread time in socket syscalls and the
      20% in JSON/HTTP are Crystal's, identical in both arms.
- [ ] Optional, RSS only: post-GC RSS is 27 MB (Boehm 26, master 15) because
      warm chunks stay resident; a time-decay release from the monitor thread
      would lower idle RSS without touching the loaded number.
- [x] Items 3–5 together: 113.3% [88.5, 138.0] of item 2 at n = 3, CPU 224 → 199 ms/10k, RSS 1.01×.
      Log: `bench/log/linux/2026-09-06-stage2-throughput/FINDINGS.md`. Branch `perf-stage2` on the PR head, unpushed.

## Headerless default (2026-09-10)

Branch `feat/headerless-default`, PR against `sdogruyol/gcry`.

- [x] Flag polarity: `flag?(:gcry_headerless)` → `!flag?(:gcry_block_headers)`
      at every code site; both flags together is a compile error; the old
      spelling alone is a no-op
- [x] CI: plain runs build headerless; the header layout keeps arms on both
      allocators (Linux, aarch64, Darwin, Windows `headers`/`freelist`, ASan);
      env-knob smoke runs nursery/freelist/TLAB on the layout that reads them
- [x] Docs: README tables and feature row, HARDENING compile-flag table +
      knob rows, PERF / PERF-macos headline tables, WINDOWS, CHANGELOG
- [x] `crystal tool format`, `make lint`, `make knob-doc-check` clean
- [x] Every Linux CI gate green on the headerless default; spec suites on all
      three layout/allocator arms (`make heap-counters` control moved to the
      header layout — the only heap with a plain counter path)
- [x] `bench/baseline/perf_smoke.json` re-recorded after merge — 23 green
      master runs, not ten: the first ten under-sampled the runner's spread
      (96.6-105.2 on `pct_json` against 93.9-108.4 across all 23) and would
      have left the gate 0.94 pp from a false alarm. 0 self-fires per metric,
      leave-one-out 23 of 23, `PERF_GATE_BASELINE=1` still declined at a
      measured 3.2% false-red rate per run.
      `bench/log/linux/2026-09-13-perf-baseline-headerless/FINDINGS.md`
