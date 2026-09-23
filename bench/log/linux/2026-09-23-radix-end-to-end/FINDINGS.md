# The chunk radix, end to end: it pays in proportion to edges, not to GC time

**Date:** 2026-09-23 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
`bench/micro/gc_phases.cr`, `GCRY_CHUNK_RADIX=0` vs default (on) · raw rows beside this file

`tasks/todo.md` has asked since the O(1) chunk table landed for "the first
end-to-end evidence the mark work pays", on the GC-bound workload built
precisely because Kemal (0.2–0.5% GC duty cycle) cannot show any mark-side
change. It was never run.

## Two points, interleaved

**Graph-heavy** — `--survival=0.5 --fanout=6 --shuffle`: 400 000 objects,
2.4 M edges, addresses shuffled across ~450 chunks. n=12 per arm.

| | radix off | radix on | Δ | t |
|---|---|---|---|---|
| `pause_per_gc_us` | 93 819 ± 1 036 | 32 726 ± 884 | **−65.1%** | −155 |
| `ns_per_alloc` (end to end) | 228.1 ± 3.0 | 93.0 ± 2.4 | **−59.2%** | −124 |
| `rss_kb` | 64 567 | 64 713 | +0.23% (the table) | +12 |
| `gc_duty_cycle` | 90.8% | 77.8% | | |

**Edge-free** — `--survival=0.1 --fanout=0`: objects hold no pointers, so
mark traces roots and little else. n=8 per arm.

| | radix off | radix on | Δ | t |
|---|---|---|---|---|
| `pause_per_gc_us` | 7 524 ± 215 | 7 365 ± 119 | −2.1% | −1.83 |
| `ns_per_alloc` | 42.8 ± 1.5 | 42.2 ± 0.9 | −1.6% | −1.12 |
| `gc_duty_cycle` | 77.4% | 77.0% | | |

## What that says

Both workloads spend ~77% of wall time in GC, and the radix is worth 59%
end to end on one and nothing measurable on the other. So its value does
not follow **GC duty cycle** — the axis the phase gates were restated on —
it follows **chunk lookups during mark**: every traced edge resolves its
target's chunk, and the table turns a `log n` binary search over a
shuffled, cache-hostile index into two loads. No edges, no lookups, no win.

That also explains the 2026-09-03 A/B's smaller number (`phase_mark`
−10–18%): a lighter graph, fewer lookups per collection. And it bounds
what any application sees: the win scales with pointer density of the
live heap times collections, and Kemal at 0.2–0.5% duty cycle sees
approximately none of it — which the item recorded as the reason this
benchmark exists.

The shipped default (radix on under the bitmap allocator) is confirmed
on the axis the gate is meant to judge, at +146 kB for the table.

`collections` rose +144% with the radix on: each cycle is cheaper, so
more allocation fits in the same 3 s. `ns_per_alloc` is the fair
end-to-end number; `pause_per_gc_us` the per-cycle one.
