# EC1 under-load phase TRACE (`/json`, d=30, c=100)

Binary: tip with extended `Trace.collect_end` (flush/static/stacks/…).

| Config | wrk req/s | collects | pause sum | flush sum | pause+flush |
|--------|----------:|---------:|----------:|----------:|------------:|
| default | **34519** (`wrk-v2.txt`) | 187 | 0.799s (2.7%) | 0.270s (0.9%) | **3.6% wall** |
| `GCRY_KEEP_CHUNKS=1` | **33654** (`wrk-keep.txt`) | 182 | 1.299s (4.3%) | 0.013s (0.0%) | **4.4% wall** |

Single-trial thr here is host-soft (campaign median-of-3 had KEEP_CHUNKS higher). Phase shape is the signal.

## Median phase — default (under load)

| Phase | med ms | % of pause | % of pause+flush |
|-------|-------:|----------:|-----------------:|
| `scrub_ns` | 0.030 | 0.8 | 0.6 |
| `roots_ns` | 0.196 | 5.0 | 3.7 |
| `static_ns` | 0.088 | 2.2 | 1.6 |
| `stacks_ns` | 0.014 | 0.3 | 0.2 |
| `mark_ns` | 0.220 | 5.6 | 4.1 |
| `sweep_ns` | 3.511 | **85.8** | **64.0** |
| `flush_ns` | 1.353 | — | **25.0** |

## Median phase — KEEP_CHUNKS (under load)

| Phase | med ms | note |
|-------|-------:|------|
| `sweep_ns` | 6.060 | larger retained heap |
| `flush_ns` | 0.067 | munmap path gone |
| `pause_ns` | 6.678 | longer STW than default |

## Verdict

1. **Mark is not the bottleneck** (~5% of pause).
2. **Sweep dominates STW** (~86% pause / ~64% pause+flush).
3. **Flush is real** on default (~25% of cycle, ~0.9% wall) and collapses with KEEP_CHUNKS.
4. **pause+flush ≤ ~4% wall** → zeroing GC stop time cannot close ~7pp thr to 95% alone.
5. Residual thr is primarily **mutator/alloc locality after reclaim** (and host noise), not mark/root.
6. **Go/no-go:** do **not** open a mark epic. Flush/alloc work is only worth a **single measured lever** with low expectation; otherwise stop and keep residual named.
