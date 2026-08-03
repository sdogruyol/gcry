# Non-stack retention A/B (2026-08-03)

Host: WSL2 / Ryzen 9 9950X. Bin: `acikturkiye-exclusive` (`GCRY_PRECISE_STACK=2`).
`wrk -c100 -d30`, med-of-3, non2xx=0. Script: `bench/acik_nonstack_ab.sh`.
Smoke (d15): `../2026-08-03-acik-nonstack/`.

## What the heap says (control)

Post-collect `size_class_live_bytes` ≈ **290–465 MiB** (median ~**382 MiB**) while
Boehm RSS ≈ **35–43 MiB**. Chunks **dense** (`chunk_fill_ge75` thousands);
`released_chunk_bytes=0`. Dual `/gc-collect`: **live bytes unchanged** — not
finalizer/floating lag.

Remaining ~8–10× is a **marked-live graph** (conservative heap edges + roots),
not empty-chunk reclaim.

## Med-of-3 knobs (RSS KiB / live MiB)

| knob | RSS med | × Boehm* | live MiB med | prec/cons (t1) | layouts |
|------|--------:|---------:|-------------:|----------------|--------:|
| control (builtins) | 306752 | ~8.6× | 382 | 636/20k | 51 |
| `GCRY_DISABLE_LAYOUT=1` | 319492 | ~9.0× | 454 | 0/18k | 0 |
| `GCRY_AUTO_LAYOUTS=1` | 335596 | ~9.4× | 444 | 11k/12k | 483 |

\*vs single boehm trial RSS 35532 (noisy low); band matches prior exclusive ~7.8–9×.

d15 floor bundle (`LARGE_CACHE=1MiB`, `EMPTY_CHUNK_RETAIN=0`) and `SCAN_CAPS`
also **no RSS win** (see smoke summary).

## Verdict

1. **AUTO_LAYOUTS** raises precise:conservative ratio and layout count (51→483)
   but **does not cut** `size_class_live` / RSS on this app.
2. **DISABLE_LAYOUT** does not help (15s “win” was noise).
3. **Empty-chunk / large-cache floor** ≪ mark-live gap (~tens of MiB vs ~400 MiB).
4. Exclusive’s earlier ~9% win vs tip base remains **mutator spill-window**, not
   heap-layout progress.

Non-stack knobs available today **do not close** the acik gap. Next levers are
heavier: root/type attribution for conservative scans, app-side layout
registration for hot types, or accepting dense-live as the stack-map / precise
heap problem (parked full scan still feeds false roots into the graph).

## Do not bother (reconfirmed)

Nursery, `PAGE_DONTNEED` default, smaller chunks, exclusivef, expecting
`EMPTY_CHUNK_RETAIN=0` to move the headline ×.
