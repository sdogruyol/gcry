# Live-attr A/B — who seeds 32 KiB atomics (2026-08-03)

Same stackmap exclusive bin; `PRECISE_MODE=0|1|2`. `GCRY_LIVE_ATTR=1`.
`wrk -c100 -d15`, dual collect. Script: `bench/acik_live_attr_ab.sh`.

## Table (atomic first-mark MiB)

| mode | max_atomic | mutator→atomic | parked→atomic | precise→atomic | heap→atomic | live |
|-----:|----------:|---------------:|--------------:|---------------:|------------:|-----:|
| 0 conservative | 87.6 | 0.1 | **8.7** | 0.0 | 78.8 | 98.7 |
| 1 hybrid | 86.0 | 0.1 | **7.6** | 1.8 | 76.8 | 103.1 |
| 2 exclusive | 84.1 | 0.0 | **5.2** | 2.7 | 76.3 | 95.0 |

## Verdict

1. **Mutator stack is not the bottleneck** for these slabs (≤0.1 MiB first-mark
   atomic). Exclusive mutator spill-window already enough here.
2. **Parked fiber word-scan** is the ambient seed (~5–9 MiB atomic first-mark).
3. **~76 MiB atomic** arrives via **heap edges** (typical: `String::Builder` /
   live refs → `malloc_atomic` buffer). Cutting parked false roots must remove
   those graph roots to move RSS.
4. Mode 0→2: parked atomic seed 8.7→5.2, max_atomic 87.6→84.1 — small. Remaining
   parked full-scan still feeds the closure. **exclusivef / denser parked maps**
   is the B lever (still UAF-blocked on acik — need map coverage, not leaf=0 alone).

## Next (B)

- Parked precise: more call-site lives on swapcontext / resume paths; keep
  `PRECISE_FIBERS` research-only until soak green.
- Optional: attribute first-mark of `String::Builder` (tid 435) by source — confirm
  parked seeds the builders that pin the 32 KiB buffers.
MD