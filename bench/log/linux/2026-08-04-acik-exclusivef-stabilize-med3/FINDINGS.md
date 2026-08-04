# exclusive / exclusivef stabilize (LEAF=8 KiB + other-thread scans)

**Date:** 2026-08-04 · tip+EC stackmap bins · WSL2 9950X  
**Method:** `acik_stackmap_ab.sh`, `VARIANTS="boehm exclusive exclusivef"`, dual `/gc-collect`.  
**Prior flake:** `…/2026-08-04-acik-exclusivef-defaults/` — 30s med3 ThreadPool crash
(2/3 exclusivef) + exclusive collect hang; LEAF forced to 0.

## Fixes (this cut)

1. **Exclusive other-thread scans restored** — `PRECISE_STACK=2` no longer skips
   EC1 `scan_other_thread_fiber_ec1` / pthread / mid-swap SP scans. Exclusive
   only skips *mutator* full-stack word scan.
2. **Mutator spill window 4 → 16 KiB** under exclusive.
3. **exclusivef default LEAF=8 KiB** (+ additive FP-fill). LEAF=0 + fill-only
   fails `stackmap_exclusive_fiber_smoke` (String slot outside tiny `[rsp,fp)`).
4. **Harness** no longer forces `GCRY_PRECISE_FIBER_LEAF=0` for exclusivef.
5. FP-chain unusable + LEAF=0 → full parked word-scan fallback per fiber.

## Med-of-3 (30s) — clean

Session: this directory. Smoke: `…/2026-08-04-acik-exclusivef-stabilize-smoke/` (15s, also clean).

| variant | thr med | % Boehm | RSS med | × | non2xx |
|---------|--------:|--------:|--------:|--:|-------:|
| boehm | 307.7 | 100% | 43332 | 1.00× | 0 |
| exclusive | 294.6 | **95.7%** | 89660 | **2.07×** | 0 |
| exclusivef | 304.3 | **98.9%** | 82808 | **1.91×** | 0 |

3/3 trials each: no SEGV, no collect hang, no Non-2xx.

## Verdict

1. exclusive / exclusivef are **correctness-stable** under 30s wrk on this host
   with the new defaults — prior flake class closed.
2. **Not an RSS win** vs tip base (~1× after finalizer + retain=0). ~2× is the
   price of exclusive mutator + leaf safety; product path stays without
   `PRECISE_STACK`.
3. Still research-only — do not promote as process defaults.
4. Darwin acik ~18× RSS proof remains the next gate (needs macOS host).

## Next

- Darwin acik exclusive/hybrid A/B (RSS gate).
- Shrink LEAF / spill further only with denser parked lives (compiler), not by
  re-disabling other-thread scans.
