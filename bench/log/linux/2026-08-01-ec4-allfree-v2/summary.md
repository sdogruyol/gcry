# EC4 stretch ~80% — ALL_FREE skip v2 + LAG prelude (REJECT)

Tip: mark-gen **76.6%** `/json`. Sweep still ~6–12 ms of pause.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Prelude — stack LAG env A/B (`wrk -c100 -d20` ×3)

| Config | thr med | roots ms | pause p50 |
|--------|--------:|---------:|----------:|
| LAG 256 (default) | **~71k** | ~7.2 | ~20 |
| LAG 128 | ~68k | ~4.6 | ~18 |
| LAG 64 | ~61k | ~4.7 | ~17 |
| LAG 128 + pthread 128 | ~71k | ~4.5 | ~17 |

Soft 0. No thr win vs 256 default — **keep LAG 256**.

## ALL_FREE v2 (code, reverted)

Sticky `ChunkHeader::ALL_FREE` set when major ends all-FREE; cleared on first
freelist pop via LIFO tip (no used_count RMW). Skip walk only under Parallel
reclaim-off + !TLAB (avoid munmap/stale-bit).

| | Soft | thr med | skips | phase_sweep |
|--|-----:|--------:|------:|------------:|
| soak ×40 | **0/40** | **~62.7k** | 56–4k cumulative | **~11–15 ms** |

Skips fire but sweep last-collect stays ~12 ms; thr **below** mark-gen ~67k
and same-host LAG256 ~71k (tip `contains?` on alloc path).

## Verdict

**Reject** stretch levers tried today. Code reverted. Campaign bar **76.6%**
stands; stretch **~80%** still open. Residual still `phase_sweep` on
mostly-empty reclaim-off heap — used_count / parallel sweep / ALL_FREE all
failed the thr bar.
