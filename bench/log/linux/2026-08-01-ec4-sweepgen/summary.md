# EC4 on-demand span reclaim (sweep generation) — REJECT

Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.
Campaign bar: lazy sweep **~78.8%** `/json`.

## Lever

Mark-only STW; bump a per-chunk sweep generation; reclaim unswept spans on
freelist miss; finish remainder before the next mark. Fresh allocs marked
while the epoch is active (no freelist drain).

## Soft soak (`wrk -c100 -d8` `/json` ×40)

| Variant | OK | soft | OK thr med |
|---------|---:|-----:|-----------:|
| freelist drain + rediscover | 40/40 | 0 | **~49.2k** |
| mark-on-alloc, no clear_mark | 40/40 | 0 | **~53.0k** |

`soak40/` = drain; `soak40-v2/` = mark path (SEGV if clear_mark mid-epoch).

## Quiet thr (`wrk -c100 -d30` med-of-3, `/json` only)

| Path | % Boehm | gcry med | Boehm med | RSS × |
|------|--------:|---------:|----------:|------:|
| `/json` | **71.9%** | 53,257 | 74,061 | **5.45×** |

vs lazy **78.8%** @ ~69k — clear regress.

## Why

Lazy post-STW already overlaps the same O(heap) reclaim with mutators under
freelist locks. On-demand reclaim adds mark-on-alloc tax + O(chunk-list)
finds + a finish pass before the next collect — **more** mutator-path work,
not less. Without per-span freelists, draining freelists to stay correct
costs ~49k; keeping them needs alloc-mark and still loses.

## Verdict

**REJECT** (reverted). Soft green; thr below bar.
