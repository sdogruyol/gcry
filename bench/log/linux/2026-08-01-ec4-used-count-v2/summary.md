# EC4 used_count all-free sweep skip — REJECT

Tip after mark-gen (76.6% `/json`). TLAB off.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

Maintain `ChunkHeader` USED-block count; skip O(blocks) sweep walk when
`used_count == 0` (all FREE freelist reserve). Goal: cut Parallel reclaim-off
`phase_sweep` (~5–7 ms) without sticky `ALL_FREE` (rejected: ~2 skips/major).

## Variants

| Variant | Mechanism | Soft | Quiet `/json` % Boehm | Notes |
|---------|-----------|-----:|---------------------:|-------|
| v1 `2026-08-01-ec4-used-count/` | SIZE 24→32 + `chunk_containing` every alloc | **0/40** | **56.3%** @ ~51k | Sweep ~7→~1 ms; mutator lookup kills thr |
| **v2 (this)** | used_count in flags[16:31]; tip cache + invalidate on rebuild/munmap; no skip under TLAB | **0/40** | **69.2%** @ ~60.5k | Sweep still ~1 ms; soak med ~66k; quiet below 76.6% bar |

## Soft soak (`wrk -c100 -d8` `/json` ×40)

| OK | soft | hard | OK thr med |
|---:|-----:|-----:|-----------:|
| **40/40** | **0** | **0** | **~66.3k** |

## Quiet thr (`wrk -c100 -d30` med-of-3, same-host Boehm)

Session `2026-08-01-105726/`:

| Path | % Boehm | gcry med | Boehm med | RSS × |
|------|--------:|---------:|----------:|------:|
| `/json` | **69.2%** | 60,508 | 87,386 | **5.81×** |
| `/` | **100.3%** | 99,638 | 99,386 | **6.28×** |

vs mark-gen baseline: `/json` **76.6%** @ ~67k → **69.2%** @ ~60k.

## Phase timings (`/json` last-collect)

| | mark-gen | used_count v2 |
|--|----------:|--------------:|
| phase_sweep | ~6.8 ms | **~0.7–5 ms** (skips fire) |
| pause p50 | ~20 ms | ~20–21 ms |
| all_free_sweep_skips | 0 | hundreds–12k |

Skips work; pause p50 flat; **mutator used_count / tip traffic regresses thr**.

## Gates

- `stw_mt_property_test --workers=2,4` (+ `--tlab`) **PASS** (v2)
- Soft **0/40**

## Verdict

**Reject.** Soft green and sweep phase cuts, but quiet thr **below** mark-gen
baseline (ship bar: ≥76.6%). Same failure class as sticky ALL_FREE: accounting
that enables skip is not free on the HTTP alloc path. Code reverted.

Next residual levers: STW parallel sweep, or RSS reclaim balance — not
used_count skip.
