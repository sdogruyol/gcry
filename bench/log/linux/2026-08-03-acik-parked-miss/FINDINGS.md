# Parked frame map-miss attribution (2026-08-03)

## Instrumentation

`GCRY_STACKMAP_MISS_LOG=1` → `/gc-stats` fields:

- `stack_maps_parked_misses` / `_oob_misses` / `_rbp_offstack`
- `stack_maps_top_miss_pcs` (top-32 unique ret PCs; `pc=0` counted but excluded from ring)

Run with exclusivef **+ FP-fill** so the process survives while recording misses.

## Dominant miss (NEAR_DELTA=32, denser emit)

| ret PC | n | symbol |
|--------|---|--------|
| `0x0` | ~1878 | FP-chain terminator (noise) |
| `0x148d99c` | ~1561 | after `callq *PQ::Connection#initialize` in DB pool `~procProc(PG::Connection)` |
| libc / `_start` | small | OOB (no Crystal maps) |

Disasm: ret is immediately after the call; nearest **below** stackmap was **74 bytes** earlier (arg `pushq` sequence between pre-call map and call). Post-call map sat **4 bytes after** ret (`addq $0x30,%rsp` then map) — walker only accepts `map_pc ≤ ret`.

`rbp_offstack=0` — parked fibers are swapcontext, not makecontext.

## Fix tried: `NEAR_DELTA` 32 → **128** (default)

| variant | status | parked_miss | oob | fill |
|---------|--------|-------------|-----|------|
| exclusive (`=2`) | ok ~106 rps | 0 | 0 | 0 |
| exclusivef + FP-fill | ok ~100 rps | 0* | 0* | ~0.6 MiB |
| exclusivef + misslog | ok | 2234 | **2234** | ~0.6 MiB |
| exclusivef nofill | **SEGV** | — | — | — |

\* miss counters only when `MISS_LOG=1`.

After the bump, **in-range Crystal misses are gone** (no more `PG::Connection` in top-N). Remaining misses are 100% OOB (libc / non-mapped).

## Verdict

1. Denser emit was necessary but not sufficient — **ret↔map slack** was the Crystal-frame gap.
2. Pure exclusivef still needs FP-fill (or equivalent) for **libc/IO** frames with no maps.
3. Product path stays `GCRY_PRECISE_STACK=2` without `PRECISE_FIBERS`.

## Next

- Shrink/disable FP-fill only for frames with map hits; keep fill for OOB/libc.
- Or accept FP-fill floor for exclusivef research.
- Optional: emit-side force map adjacent to call (patchpoint) so delta can shrink again.
