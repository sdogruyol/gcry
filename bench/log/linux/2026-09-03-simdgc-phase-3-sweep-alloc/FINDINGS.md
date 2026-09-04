# Phase 3 measured: the sweep collapses and allocation gets faster

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 · `simdgc` @ 778b956
`bench/micro/gc_phases`, paired n=20, interleaved, `--live=200000 --survival=0.05`
(95% garbage — sweep-dominated), `GCRY_BITMAP_ALLOC=1` vs default header path.

## Result

| metric | header | bitmap | diff | t | wins |
|---|---|---|---|---|---|
| `phase_sweep` | 8319.6 µs | **32.2 µs** | **−99.6%** | −99.20 | 20/20 |
| `ns_per_alloc` | 82.9 ns | **59.9 ns** | **−27.8%** | −68.60 | 20/20 |

Both are the largest, most decisive effects measured on this branch, and both
are exactly what the plan predicted:

- **Sweep → ~0.** The streaming `occ &= mark` kernel replaces a walk over every
  block header with a popcount over `bitmap_words` words per chunk. At 95%
  garbage the header walk visits essentially every block; the kernel does not
  read a single header. 8320 → 32 µs is the `simdgc.c` "54 ms → 0.6 ms" result
  reproduced on different hardware.

- **Allocation faster, which 2026-08-01 could not achieve.** The pool cursor
  (`tzcnt` / `blsr` / one `occ` store) beats the freelist's `next_free` chase
  plus FREE-flag write. This is the exact metric
  `bench/log/linux/2026-08-01-ec4-alloc-bits` *regressed* (54k → 44k on /json),
  and the reason this design does not is the reason it was built the way it is:
  `occ` **replaces** the freelist rather than being maintained beside it. The
  −27.8% is the vindication of that decision.

## What it means for the plan

Phase 3's two headline claims — "sweep → ~0" and "alloc ≤ baseline" — are met,
the second decisively exceeded. On a GC-bound workload the bitmap representation
now wins on all three phases:

- `phase_sweep` −99.6% (this)
- `ns_per_alloc` −27.8% (this)
- `phase_mark` −11% (778b956, and −8% even on the header path)

## The Kemal caveat, unchanged

None of this is yet shown on Kemal, and the duty-cycle arithmetic
(`2026-09-03-simdgc-chunk-radix-ab`) says why sweep and mark will not move Kemal
throughput: sweep is already lazy/off-pause there and GC is 0.2–0.5% of wall
time. But **`ns_per_alloc` is different** — it is on the mutator's own hot path,
paid on every allocation, not inside the GC pause. That is the one axis of this
work with a credible path to end-to-end Kemal throughput, and it is the Phase 6
claim the plan reserved for the allocator. Measuring it on Kemal needs the
bitmap allocator hardened for sustained HTTP concurrency first — the concurrency
bugs fixed in 3051edb were found only three commits ago — so it is owed, not
banked.
