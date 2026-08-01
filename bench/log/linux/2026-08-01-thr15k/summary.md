# +1.5k thr chase (EC1)

## Diagnosis

Tip (512 B + `clear_range_safe` scrub) retained ~**4×** `live_objects` vs
bebedae (stack type_id_gate stays off — Channel SEGV). Scrub volume
~9 MB vs ~60 MB.

## Levers kept

1. **EC1 4 KiB blind scrub** (Parallel unchanged: 512 + safe).
2. **`heap_counters_atomic`** only when `EC_PARALLELISM>1` — EC1 plain get/set
   on alloc/free counters.

Rejected: `GCRY_THRESHOLD=40MiB` (thr down).

## Quiet cut `2026-08-01-093130` (GO on gate)

| Path | % Boehm | Boehm med | gcry med | RSS × |
|------|--------:|----------:|---------:|------:|
| `/json` | **86.8%** | 35,780 | 31,067 | 0.80× |
| `/` | 77.5% | 84,745 | 65,668 | 0.80× |

soft=0. `/json` is the release gate. `/` still soft — re-cut before PERF if
needed.
