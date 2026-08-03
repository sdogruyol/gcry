# 9950X under-load phase profile (`/json`, tip `0193d7e`)

Post-STW sweep is on tip. Samples are **last-collect** phase fields from
`/gc-stats` after each med-of-3 trial (indicative; not a full TRACE sum).

| Config | session | `/json` % | RSS × | pause_p50 | flush last | sweep last | unmapped |
|--------|---------|----------:|------:|----------:|-----------:|-----------:|---------:|
| default | `072954/` | **80.3%** | **0.76×** | 0.33 ms | ~0.6 ms | ~0.6 ms | ~4.9 GB |
| default | `072122/` | **82.5%** | **0.76×** | 0.33 ms | ~1.3 ms | ~1.0 ms | ~4.9 GB |
| `KEEP_CHUNKS=1` | `080248/` | **90.1%** | **3.23×** | 0.33 ms | ~0.005 ms | ~2.1 ms | ~0 |

## Verdict

1. **Mark/roots/scrub are not the thr gap** (sub-0.1 ms last phases).
2. **Flush/munmap is the reclaim tax** on default (GB-scale `unmapped_bytes`
   over a 30s wrk; KEEP collapses flush).
3. **KEEP recovers ~8–10 pp thr** on this host (80–83% → **90%**) at **~3.2×**
   RSS — soft thr bar hit, RSS gate fail. Ceiling confirmed.
4. pause+flush still a few % of wall → zeroing GC time alone cannot reach
   95%@≤1.0×. Residual is **mutator/alloc locality after reclaim**.
5. Next lever: **warm empty-chunk retain** (mapped, no DONTNEED) as middle
   path between default munmap and KEEP.
