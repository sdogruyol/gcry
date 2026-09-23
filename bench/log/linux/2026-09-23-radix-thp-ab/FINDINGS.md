# Does `MADV_NOHUGEPAGE` on the chunk-radix tables cost the mark? No — and until today it could not be asked

**Date:** 2026-09-23 · host: Linux 7.0.0-31-generic x86_64 (QEMU), THP `madvise`,
Crystal 1.21.0 · `bench/micro/gc_phases.cr`, `runs.tsv` beside this file

The radix tables are `MADV_NOHUGEPAGE`d because under THP `always` one
touched entry faults a 2 MiB page (+16–21% post-GC RSS on Kemal,
`2026-09-03-simdgc-chunk-radix-ab`). `GCRY_RADIX_THP=1` exists to ask the
other half — the huge page also gives the table one TLB entry, so does
giving it up cost some of the mark win? `tasks/todo.md` carried that
question twice, marked "in flight", for a month.

## Why it had never been answered

The knob only **skipped** `MADV_NOHUGEPAGE`. Under THP `always` that is
enough; under `madvise` — Ubuntu's default, and GitHub's runners' — a
region gets a huge page only if it asks with `MADV_HUGEPAGE`, and nothing
asked. Measured with the radix live (16 163 fast hits):

| `GCRY_RADIX_THP` | `AnonHugePages` (process total) |
|---|---|
| 0 | 0 kB |
| 1, before | **0 kB** |
| 1, after | **2048 kB** |

So the A/B was not merely unrun; on both hosts that run this project it
was untakeable. The knob requests `MADV_HUGEPAGE` now.

## The A/B

A workload where mark *is* the program: `gc_phases --seconds=3
--survival=0.5 --fanout=6 --shuffle` — 400 000 graph objects, 2.4 M
edges, **78% GC duty cycle**, 237 M radix lookups in 3 s. n=12 per arm,
interleaved with alternating order.

| metric | `MADV_NOHUGEPAGE` | `MADV_HUGEPAGE` | Δ | t |
|---|---|---|---|---|
| `pause_per_gc_us` | 33 660 ± 905 | 33 190 ± 873 | −1.40% | −1.30 |
| `rss_kb` | 64 691 ± 45 | 66 806 ± 587 | **+3.27%** | **+12.45** |
| `ns_per_alloc` | 95.6 ± 2.4 | 94.6 ± 2.5 | −1.08% | −1.02 |

The TLB entry buys nothing this benchmark can distinguish from noise, on
the workload most favourable to it; the page costs 2 MiB every time. The
default stays, now with its own number rather than an argument.

`pause_per_gc_us` rather than `phase_mark_us`: the latter is one
last-collection sample, the former a mean over ~70 collections a run.
