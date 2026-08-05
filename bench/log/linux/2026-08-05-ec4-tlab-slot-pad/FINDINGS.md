# Phase C.2 — Cache-line pad `@tlab_slot_locks` — **REJECT**

**Date:** 2026-08-05 · Host: WSL2 R9-9950X · Crystal 1.21.0  
**Branch:** `plan/parallel-tlab-on`  
**Pad commit:** `c755780` (reverted in tree after this cut; do not keep)

## Hypothesis

C.1 saw ~**193 ns** slot-lock **wait**/hit on per-thread TLABs → suspected
false-sharing of packed 4 B `Crystal::SpinLock` in `StaticArray`. Pad each
lock to **64 B**.

## Method

Same harness as C.1: `/tmp/kemal-gcry-pad`, `wrk -c100 -d20 -t4 /json`,
`EC_PARALLELISM=4`. Compare to C.1 hub
`…/2026-08-05-ec4-tlab-hit-attr/`.

## Results

| Cut | wrk `/json` | wait avg | hold avg | wait % crit |
|-----|------------:|---------:|---------:|------------:|
| C.1 B1+attr (pre-pad) | 47 102 | **193.4 ns** | 141.1 | 57.8% |
| C.2 B1+attr t1 | 48 344 | **212.5 ns** | 141.2 | 60.1% |
| C.2 B1+attr t2 | 44 519 | **222.8 ns** | 148.8 | 60.0% |
| C.1 B1 noattr | 55 447 | — | — | — |
| C.2 B1 noattr | 56 757 | — | — | — |

`find_block` still ~64 ns · ~18% of crit (unchanged shape).

### TLAB-off gate (pad tip; path does not use `@tlab_slot_locks`)

| | wrk `/json` |
|--|------------:|
| t1 / t2 / t3 | 81.5k / 84.4k / 82.8k |
| **median** | **82.8k** |
| A4 quiet med3 d=30 (pre-pad era) | ~107.9k |

Soft vs A4 — likely host/method (d=20 single-process med3 vs quiet med3
d=30), **not** attributed to pad (TLAB-off never takes padded locks). No
same-harness pre-pad off control today.

## Verdict — **REJECT**

1. **wait did not drop** (193 → 213–223 ns). False-share hypothesis for the
   C.1 wait signal is **not supported** by this lever.
2. B1 noattr thr flat (~55–57k); no product thr win.
3. **Revert** `PaddedSpinLock`; keep C.1 attr knob for the next lever.

## Next (C.3)

Re-interpret ~200 ns “wait”: likely **SpinLock CAS / pause cost** (and
attr `clock_gettime` sandwich), not cross-slot false sharing — or
same-slot contention from free/refill on that thread’s slot.

Next lever candidates (one at a time):

1. Epoch-gated / hot-head skip of `find_block` (~19% of crit) — soft-soak
   gated; historically SEGV-sensitive.
2. Shrink hold (mark/counters already outside `@alloc_lock`).
3. Accept thr gap; document unsupported TLAB-on Parallel thr residual.
