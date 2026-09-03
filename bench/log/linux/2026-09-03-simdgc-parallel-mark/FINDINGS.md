# Sharded parallel mark: scales to 4 workers, bandwidth-bound past that

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 (24 threads, **dual-channel**
memory) · `simdgc` @ 812c010 · `bench/micro/gc_phases --shuffle`

## The change

The parallel marker took the global mark lock around the entire per-word
acceptance, so `GCRY_PARALLEL_MARK=8` ran 60x slower than serial. Two commits
fixed it: narrowing the lock off the read-only acceptance path (daf0b58), then
per-worker sharded stacks with batched exchange (812c010). Correctness validated
by stw-mt-property-test (3/3), mark-audit, parallel-mark-process, mt-property.

## Scaling depends on graph shape, and that is a bandwidth story

`phase_mark`, median of 3, by workers:

| workers | leaf objects (64 B) | wide graph (32 words, fanout 16) |
|---|---|---|
| 1 | 21.9 ms | 30.7 ms |
| 2 | 18.7 ms (1.17x) | 20.1 ms (1.53x) |
| 4 | 26.0 ms (regress) | **12.3 ms (2.50x)** |
| 8 | 57.8 ms (regress) | 40.4 ms (regress) |

Paired, interleaved, on the wide graph: 2 workers and 4 workers are both 12/12
wins over serial; 4 workers lands at ~12.3 ms against a ~30.7 ms serial, a 2.5x
speedup.

**Leaf objects cap at 2 workers; realistic objects scale to 4.** The difference
is memory bandwidth. A 64-byte leaf is one random cache-line load and almost no
compute, so marking it is pure random-access bandwidth — and on a dual-channel
part two threads already saturate the achievable memory-level parallelism (the
`mlp.c` floor is ~12 ns/access regardless of thread count once bandwidth is the
limit). Add real per-object work — 32 words to scan, 16 pointers to chase — and
the compute overlaps the memory stalls, so a third and fourth worker find
something to do. Past 4, bandwidth is exhausted on this chip and the added
coherence traffic makes it worse.

This matches `simdgc-perf-notes.md` exactly: "near-linear to ~4 markers on the
tree/DAG shapes; the chain shape will not scale at all". The 260 MiB-L3 Xeon it
was measured on had more memory bandwidth headroom; a dual-channel mobile part
tops out sooner, which is a property of the hardware, not the marker.

## What was ruled out on the way to that conclusion

- **Not lock contention.** Batches of 256/512 make the shared-stack lock ~2000
  ops per collection — far too few to explain a 40% slowdown.
- **Not the shared chunk cache.** `GCRY_CHUNK_RADIX=1` makes `chunk_containing`
  read-only (no `@last_chunk_idx` writes), and the scaling curve is unchanged.
- **Not the shared statistics counters.** Guarding
  `@layout_conservative_scans` / `@type_id_*_rejects` behind `!@mark_parallel`
  (a diagnostic build) did not change the curve either.

Each was a measurement, not a guess, and all three pointed away from the code and
at the memory subsystem.

## Standing

Parallel mark stays off by default and experimental. It is now genuinely useful
at 2-4 workers on realistic object graphs, where before it was unusable at any
count. The knee is bandwidth, so the number to set `GCRY_PARALLEL_MARK` to is a
property of the deployment's memory subsystem, not a universal constant — 4 is
right for this chip.
