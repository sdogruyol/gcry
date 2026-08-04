# Kemal thr profil — munmap / alloc locality (9950X)

**Date:** 2026-08-04 · Host: WSL2 **Ryzen 9 9950X** · Crystal 1.21.0  
**gcry:** `stack-maps` @ `7e16569` · tip+EC · Linux retain=0 defaults  
**Method:** `FORCE_REBUILD=1 TRIALS=3 WRK_DURATION=30` · `wrk -c100 -d30`  
**Sessions:** default `…/2026-08-04-073342/` · KEEP `…/2026-08-04-074045/`

## Headline

| Config | `/json` % Boehm | RSS × | gcry rps (med) | Boehm rps (med) |
|--------|----------------:|------:|---------------:|----------------:|
| tip default | **79.6%** | **0.79×** | 37,425 | 47,012 |
| `KEEP_CHUNKS=1` | **82.8%**† | **~3.4×**† | 38,941 | (same Boehm) |

† KEEP run was `GC=gcry` only; %/RSS× vs default-session Boehm med / RSS.

Soft ≥90%@≤0.85× and hard ≥95%@≤1.0× still **MISS** (expected).

## Absolute thr vs % of Boehm

| Session | Host | Config | gcry `/json` | Boehm `/json` | % |
|---------|------|--------|-------------:|--------------:|--:|
| `042404/` | 9950X morning | default | 35,061 | 41,259 | **85.0%** |
| `043747/` | 9950X morning | KEEP | 36,536 | 39,472 | **92.6%** |
| `073342/` | 9950X office | default | **37,425** | **47,012** | **79.6%** |
| `074045/` | 9950X office | KEEP | **38,941** | (47,012) | **82.8%** |

- Default→KEEP absolute delta ≈ **+1.5k rps (~4%)** both morning and office.
- Morning “KEEP +8–10 pp” was largely **Boehm quieter** (39–41k), not a
  larger gcry leap. Office Boehm loud (47k) → same gcry absolute looks worse %.
- Office default gcry is **faster** than morning default in absolute rps;
  gate % alone misleads under host/Boehm noise.

## Munmap / phase anatomy (`/json`, med-of-3 last-collect fields)

| | default | KEEP |
|--|--------:|------:|
| `unmapped_bytes` / trial | **~7.3–7.9 GB** | **0** |
| `phase_flush_ns` (last) | ~1.1–2.1 ms | ~0.004 ms |
| `phase_sweep_ns` (last) | ~0.6–0.9 ms | ~1.8–3.4 ms |
| `pause_p50` | ~0.39 ms | ~0.41 ms |
| `pause_total` / 30s wall | ~79 ms (**0.26%**) | ~86 ms (**0.29%**) |
| `heap_size` | ~16.6 MiB | ~54.3 MiB |
| `fully_free_chunk_bytes` | ~26 MiB (then released) | ~38 MiB (kept mapped) |
| `chunk_fill_lt25` | ~26 | **~328** |

Mark/roots/stacks/scrub last phases remain sub-0.1 ms — not the thr gap.
`pause_total` ≪ wall → zeroing STW cannot buy ≥90%@≤0.85×.

## Alloc locality read

1. **Flush/munmap tax is real but small in wall time** (~GB unmap; last flush
   ~1–2 ms; KEEP collapses it). Matches prior phase TRACE (pause+flush ≤~4% wall).
2. **KEEP thr gain is small in absolute rps (~4%)** once Boehm noise is
   removed — locality from keeping empties mapped helps, but not enough for
   the soft bar at ≤0.85× RSS (KEEP sits ~3.4×).
3. Post-reclaim heap stays dense on default (~16 MiB, fill mid-band); KEEP’s
   `fill_lt25` explosion is retained empties, not denser live packing.
4. Residual thr to soft/hard bars is **mutator/alloc locality + host noise**,
   not mark/root/scrub. Shard-only retain knobs remain exhausted
   ([018-FINDINGS](../2026-08-02-018-FINDINGS.md)).

## Gate

| Gate | Result |
|------|--------|
| ≥90% @ ≤0.85× | **MISS** |
| ≥95% @ ≤1.0× | **MISS** |

## Next

Mostly-empty reclaim (option 2) targets **acik RSS residual** (mapped freelist
/ sparse chunks), not this Kemal thr miss. Do not sell KEEP / PAGE_DONTNEED
as thr or RSS default wins.
