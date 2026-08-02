# EC4 alloc-bitmap sweep skip (REJECT)

Tip: lazy-sweep **78.8%** `/json`. Stretch ~80%.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever (reverted)

Per-chunk allocation bitmap at mapped tail: power-of-two aligned small
mmaps for O(1) `user→chunk`; set bit on alloc, clear on free/reclaim;
sweep iterates set bits / skips empty bitmaps.

## Smoke A/B (`wrk -c100 -d8` `/json`, same binary)

| Config | thr | sweep ms | skips | visited |
|--------|----:|---------:|------:|--------:|
| allocBits on | **~44k** | ~19.7 | 0–2 | ~465k ≈ live+dead |
| `GCRY_DISABLE_ALLOC_BITS=1` | **~54k** | ~18.9 | 0 | — |

Soft: 0 on smoke. Bits stay coherent (visited ≈ live set, not unbounded
stale). Empty-bitmap skips ~0 under reclaim-off freelist churn. Dense
death makes bit iteration no cheaper than sequential header walk; mutator
bit-set + aligned mmap tax thr.

`stw_mt_property_test --workers=2,4` PASS before revert.

## Verdict

**Reject** (code reverted). Same structural limit as dirty∪marked skip:
Parallel reclaim-off empties are the hot freelist — sweep work tracks
alloc churn, not spare capacity. Stretch ~80% still open; bar **78.8%**.
