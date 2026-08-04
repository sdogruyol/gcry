# Darwin acik stackmap A/B (item 29)

**Date:** 2026-08-04 · Apple M2 Pro · tip+EC (`75a9d25` + Darwin Mach-O/aarch64 walker)  
**Method:** `acik_stackmap_ab.sh`, `VARIANTS="boehm base hybrid exclusive exclusivef"`,
`TRIALS=3` `WRK_DURATION=30`, dual `/gc-collect`, `REQUIRE_2XX=1`.  
**Probe:** sibling `../crystal` `gcry-stackmap-probe` @ `4a965f423` (rebuilt on this Mac).  
**Boehm:** system Crystal 1.21.0. Demo DB seeded (405 submissions).

## Blockers cleared on this host (before the cut)

1. **Stale probe compiler** — `.build/crystal` was July `c9d4dec` (no emit). Rebuilt
   → IR + `__LLVM_STACKMAPS,__llvm_stackmaps` in objects/binaries.
2. **Loader was Linux-only** — `StackMaps.load_from_exe` now reads Mach-O via
   `Platform::LibDyld` (image 0).
3. **Walker was x86_64-only** — aarch64 mutator FP walk + parked aarch64-generic
   spill layout + DWARF FP=29 / SP=31. `make stackmap-smoke` + exclusive fiber
   smoke **OK** on Darwin.
4. **Stale `acikturkiye/lib/gcry` copy** (0.16) shadowed path shard — `shards update
   gcry` → symlink to tip.

## Med-of-3 (30s)

Source: `acik-stackmap.tsv` / `summary.md`.

| variant | thr med | % Boehm | RSS KiB med | × Boehm | marked | records | non2xx |
|---------|--------:|--------:|------------:|--------:|-------:|--------:|-------:|
| boehm | 1004.0 | 100% | 57568 | 1.00× | 0 | 0 | 0 |
| **base** | **902.8** | **89.9%** | **36480** | **0.63×** | 0 | 0 | 0 |
| hybrid | 869.1 | 86.6% | 49472 | 0.86× | 210 | 152511 | 0 |
| exclusive | 862.9 | 85.9% | 73376 | 1.27× | 225 | 305663 | 0 |
| exclusivef | 849.0 | 84.6% | 67040 | 1.16× | 225 | 305663 | 0 |

Trial 3 soft thr on hybrid/exclusive/exclusivef (~570–620 abs) — host noise;
medians still in the 70%+ band. 0/15 Non-2xx / collect hang / SEGV.

Post-GC `size_class_live_bytes` (t2): base ~6.5 MiB, hybrid ~8.8 MiB,
exclusive ~6.1 MiB. Darwin `empty_chunk_retain` still 512 KiB (not Linux retain=0).

## Verdict

1. **Darwin ~18× RSS gate is closed on tip base** — vs v0.17 fair cut
   (`…/2026-08-02-085522/`: ~71% @ **18.4×**). Tip+EC base ≈ **90% @ 0.63×**.
   Win tracks the finalizer / tip stack-maps work already on the branch, **not**
   exclusive stackmaps.
2. **Stackmaps work on Darwin** — Mach-O section present; hybrid/exclusive mark
   precise roots (`marked≈210–225`, records 152k / 306k). Smoke green.
3. **exclusive / exclusivef are not an RSS win** vs tip base (same Linux story:
   ~1.2× vs 0.63×). Research-only; product path stays **no** `PRECISE_STACK`.
4. Success bar from handoff (material RSS drop vs ~18×, thr ~70%+) — **HIT**
   on product tip; stackmap variants hold thr but lose RSS vs base.

## Next

- Product Darwin headline = tip **base** (document in ACIKTURKIYE-macos).
- Do not promote exclusive/hybrid as Darwin RSS path.
- Optional: Darwin `GCRY_TIGHT_GROW` smoke; Kemal tip re-cut on this Mac.
- Open PR `stack-maps` → master when ready (include Darwin loader + aarch64 walker).
