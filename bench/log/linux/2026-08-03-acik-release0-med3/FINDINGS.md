# release0 med3 — zero large-cache + empty-chunk retain

**Date:** 2026-08-03 · **Host:** WSL2 9950X · tip+EC `acikturkiye-base`  
**Method:** med-of-3, `wrk -c100 -d30`, dual `/gc-collect`, process RSS.  
**release0:** `GCRY_LARGE_CACHE=0` + `GCRY_EMPTY_CHUNK_RETAIN=0`

## Result

| variant | thr med | % Boehm | RSS KiB med | × Boehm | live_sc MiB |
|---------|--------:|--------:|------------:|-------:|------------:|
| boehm | 136.2 | 100% | 44972 | **1.00×** | — |
| base (defaults) | 127.4 | 93.5% | 98332 | **2.19×** | 17.5 |
| **release0** | **127.7** | **93.7%** | **44812** | **1.00×** | 12.7 |

release0 trials RSS: 44812 / 37740 / 62652 KiB (t3 noisy high; median still ties Boehm).

## Read

- Thr holds (~94% Boehm) with both caches zeroed — no thr cliff in this cut.
- Default `base` residual is allocator retain (32 MiB large-cache + 16 MiB empty),
  not live-graph / finalizer leak.
- Same-session default × (2.19×) is a bit worse than prior gate 1.81× — trial noise;
  release0 closes it either way.

## Product default?

**Not flipped yet.** Opt-in via env is proven on this host/workload. Shipping as
Linux process default needs a conscious POLICY call (mmap churn risk on other
apps; prior empty-retain / large-cache floors were thr-motivated).
