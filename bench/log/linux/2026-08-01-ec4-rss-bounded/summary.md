# EC4 bounded Parallel dormant (RSS reclaim)

Tip after mark-gen (76.6% `/json`, RSS ~5.8×) and sweep rejects. TLAB off.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

`GCRY_PARALLEL_DORMANT=1` used to DONTNEED **all** empties when munmap was
off (`can_dormant` escaped `empty_chunk_retain`). **Ship:** honor retain
budget; excess empties stay freelist-mapped (link after deferred fully-dead
path). Legacy unbounded: `GCRY_PARALLEL_DORMANT_ALL=1`. Parallel **default
still off** (thr below campaign bar).

## A/B (`wrk -c100 -d20` `/json` ×3)

| Config | thr med | RSS med (KiB) | dormant bytes |
|--------|--------:|--------------:|--------------:|
| gate (default) | **~67k** | **~110k** | 0 |
| bound **16 MiB** | ~46k | ~61k | 16 MiB |
| bound **32 MiB** | **~63k** | **~28k** | 32 MiB |
| bound 64 MiB | ~49k | ~23k | 64 MiB |
| bound 128 MiB | ~57k | ~16k | ~80 MiB |
| dormant-all | ~59k | ~16k | ~80 MiB |

## Quiet thr (bound-32 MiB, `wrk -c100 -d30` med-of-3)

| Path | % Boehm | gcry med | Boehm med | RSS × |
|------|--------:|---------:|----------:|------:|
| `/json` | **71.7%** | 62,941 | 87,815 | **1.71×** |
| `/` | **81.7%** | 111,250 | 136,174 | **2.26×** |

vs mark-gen gate: `/json` **76.6%** @ ~67k, RSS **5.80×**.

## Soft soak (bound-32, `wrk -c100 -d8` ×40)

| OK | soft | hard | thr med | rss med |
|---:|-----:|-----:|--------:|--------:|
| **40/40** | **0** | **0** | **~63.1k** | **~30 MiB** |

## Gates

- `stw_mt_property_test --workers=2,4` + `GCRY_PARALLEL_DORMANT=1` **PASS**
- `spec/collect_spec` **PASS**

## Verdict

**Ship opt-in** (bounded `PARALLEL_DORMANT` + `PARALLEL_DORMANT_ALL`). Soft
green; RSS **~1.7×** Boehm at retain=32 MiB. **Do not default** on Parallel
EC: quiet thr **71.7%** &lt; mark-gen **76.6%** bar. RSS-sensitive apps:
`GCRY_PARALLEL_DORMANT=1 GCRY_EMPTY_CHUNK_RETAIN=33554432`.
