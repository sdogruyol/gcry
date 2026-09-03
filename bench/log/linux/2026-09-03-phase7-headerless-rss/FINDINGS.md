# Phase 7.7 — the payoff, measured: up to −44.8% RSS on small objects

Date: 2026-09-03 · host: WSL2 · branch `simdgc-headerless` · `-Dgcry_headerless`
1 000 000 live 16-byte-chained objects, rooted from the stack, collected, then
the whole chain walked to prove every link survived. No arrays and no large
allocations, so this isolates the case the phase exists for.

## Result

| object | header build | headerless | saving | theory `16/(16+n)` | chain intact |
|---|---|---|---|---|---|
| **16 B** | 35 008 kB | **19 312 kB** | **−44.8%** | 50% | both ✓ |
| 32 B | 50 804 kB | 35 028 kB | −31.1% | 33% | both ✓ |
| 64 B | 81 736 kB | 66 248 kB | −18.9% | 20% | both ✓ |
| 128 B | 144 472 kB | 128 864 kB | −10.8% | 11% | both ✓ |

At 1.5 M × 16 B the saving is **50 792 → 27 400 kB, −46.1%**.

Every measured value tracks `16/(16+payload)` and sits just under it, which is
the bitmaps: halving `block_bytes` doubles the blocks per chunk and so doubles
`occ` and `mark`. The model is confirmed, including its second-order term.

**Correctness holds where it was measured.** All 1 000 000 (and 1 500 000) chain
links survived collection in the headerless build. Marking, sweeping and
allocation are all working on small objects with no per-block header at all.

## What this does not yet say — the build is partial

Headerless works for **small objects only**. `bench/micro/gc_phases` still
crashes under it, and the reason is structural rather than a loose end:

**Large objects keep their metadata in the block header.** `cache_large_chunk`,
`@pending_large_cache` and the large freelists all chain large blocks through
`header.value.next_free`, and `sweep_large` *writes* that link. With no header
those writes land on the object's own bytes — and a Crystal `Array`'s buffer is
a large object, which is why anything holding an array corrupted immediately.

Partly addressed here: large chunks now reserve a real header **inside the
metadata region** (`ChunkHeader.large_header` / `large_user` /
`large_data_offset`), so the object and its header no longer overlap, and
`set_used_large` writes it where the small-block `set_used` is a no-op. That
fixed the small-live-count cases. The rest of the large path — roughly 40 sites
across `heap.cr` and `collect_sweep.cr` — still assumes `data_start` is a header
and a user pointer is `header + 16`, and each fix has revealed another.

## The ledger, now that both sides are measured

| | 16 B-dense | 64 B-dense | Kemal |
|---|---|---|---|
| **payoff** | **−44.8% RSS** | −18.9% RSS | ~0.1% |
| 7.2 chunk kinds | +7.9% RSS (mixed-kind only) | same | +7.9% |
| 7.4 finalizer index | +9.5% free path | same | same |
| 7.6 size from chunk | +7.1% `phase_mark` | same | same |

For a small-object-dense heap the payoff is **five to six times** the RSS it
costs, and it dwarfs the two throughput costs. For Kemal it remains a clear
loss. The phase is a real win, on a workload gcry does not currently ship
against — which is exactly what the payoff-ceiling FINDINGS predicted, now
confirmed by measurement rather than arithmetic.

## Standing

`-Dgcry_headerless` is an **incomplete, experimental build**. It must not be
used for anything holding a large object. The header build is unaffected and
fully gated (spec 222/222, invariants, mark-audit, property, mt-property,
stw-mt-property, ameba, format all green).

Remaining to finish the phase: relocate large-object metadata into the chunk
(the ~40 sites), then port the six diagnostics with their purpose-broken gates
observed red.
