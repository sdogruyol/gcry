# Live-attr probe 3 — tightened typed/collision/raw (2026-08-03)

Host: WSL2 9950X. Tip Crystal 1.22 + stackmaps. Exclusive
`GCRY_PRECISE_STACK=2` + `GCRY_LIVE_ATTR=1`. `wrk -c100 -d15`, dual collect.

## Headline

| | MiB |
|--|--:|
| total (attr walk) | 96.1 |
| **typed** (real headers / String shape) | **3.8** |
| **collision** (type_id-looking word on big block) | **71.3** |
| raw | 21.0 |
| size_class_live (gcstats) | 84.5 |

first_mark: stack 5.4 / precise 2.0 / heap 85.0. Maps loaded (hits ~64k).

## Max size-class (32768) = the story

| | MiB |
|--|--:|
| class total | **82.7** (n=2658) |
| typed | 0.8 |
| collision | 69.5 |
| raw | 12.4 |
| **atomic** | **82.7** (100%) |
| ptrish (≥25% heap words) | 0.1 |
| **byteish** | **81.8** |

## Verdict

1. Prior “type_id 88/49 = Array(…)” was **false**: those are collision labels on
   oversized blocks. Real typed live is only ~4 MiB (`String` dominates).
2. ~83 MiB @ 32 KiB is **`malloc_atomic` byte buffers**, not pointer-carrying
   Array/Hash backing stores (ptrish ≈ 0).
3. Layout registration (C) / AUTO_LAYOUTS cannot reclaim this — nothing to scan
   precisely inside atomics.
4. Retention path is **conservative roots → atomic slabs → dense live**. Next
   product lever is **B: denser/correct stackmaps** (cut false roots that seed
   the graph), not app layouts.

## Do not chase

- `Array(Crystal::Var)` / `Array(Set(String))` as acik types
- More AUTO_LAYOUTS / scan_caps for this band
MD