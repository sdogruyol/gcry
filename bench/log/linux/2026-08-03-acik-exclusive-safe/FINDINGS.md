# Exclusive runtime safety (2026-08-03)

Host: WSL2 / Ryzen 9 9950X. Demo DB OK (non2xx=0).
`wrk -c100 -d15`, 1 trial. Session: this directory.

## What landed

**gcry runtime**
- Parked-fiber precise walk (x86_64-sysv spill slots + ret + FP climb)
- Exclusive mutator: setjmp regs + ~4 KiB spill window (no full SP→bottom)
- `GCRY_PRECISE_FIBERS=1` — opt into pure parked-fiber exclusive

**Crystal probe (`gcry-stackmap-probe`)**
- Stackmaps after invoke (emit in `invoke_out`, nounwind)
- Rebuild tip compiler required

**Harness**
- `--frame-pointers=always`, `CRYSTAL_STACKMAP_PER_FUN=256` for map variants

## Acik exclusive (`=2`, parked word-scan ON)

| variant | thr | thr % Boehm | RSS | × | marked |
|---------|----:|------------:|----:|--:|-------:|
| boehm | 258 | 100% | 43 MiB | 1.00× | 0 |
| exclusive | 255 | **99%** | 188 MiB | 4.38× | 2023 |

No SEGV. Thr holds. RSS ≈ base band (15s) — parked conservative scan still on,
so no RSS claim.

## Pure fibers (`GCRY_PRECISE_FIBERS=1`)

| Check | Result |
|-------|--------|
| `make stackmap-smoke` parked-fiber | **PASS** |
| acik exclusive + fibers=1 | **SEGV** (`render_500` / null deref) — prior sessions |

Maps still miss fat `--release` park/exception frames. Do not enable fibers
exclusive on acik yet.

## Next

1. Densify lives at IO-park / Hash / exception paths (emit + PER_FUN strategy)
2. Re-try acik with `GCRY_PRECISE_FIBERS=1` until no SEGV
3. Then med-of-3 RSS vs ~8.5–9× baseline
