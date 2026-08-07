# Default-path control, master vs branch, on the trace instrument

**Host: i3-12100F (4c/8t, one 12 MiB L3), WSL2** — not the 9950X that the
office session's figures come from.

`feat/sound-defaults` adds three guards to the hot mark path. Against `master`,
both builds interleaved in one job at default configuration, 9 reps × 30 s,
~1690 steady-state collections each:

```
config       n     roots   static  stacks   scrub    mark    sweep   pause
branch    1689     181.8    92.8    14.3     26.2   235.0   2297.8   560.7
master    1693     179.7    92.5    14.4     26.4   232.8   2267.2   556.9
```

## What was measured, and why not just `roots_ns`

The previous handover expected the added cost to live "directly in `roots_ns`".
The diff says otherwise:

```crystal
- return if (addr & (sizeof(Void*).to_u64 - 1)) != 0
+ return if !@scan_unaligned_candidates && (addr & ...) != 0      # ×2
- base_only = size >= 4 && !type_id_plausible?(header)
+ base_only = !@allow_interior_pointers && size >= 4 && ...
```

The first two are in `mark_candidate_unlocked` / `mark_noscan_unlocked`, which
run for every root candidate (`roots_ns`, `static_ns`, `stacks_ns`) *and* for
every heap edge during the trace (`mark_ns`). The third is only in the body
scanner, i.e. purely `mark_ns`. A `roots_ns`-only bound would have missed the
half of the change that lives in the trace.

## Result: still not resolved, and ~0.3% SEM was never available

Paired across the 9 reps (branch − master, % of master):

| phase | Δ | SEM | t | 95% CI |
|---|---:|---:|---:|---|
| roots | +1.30% | 0.89 | +1.45 | −0.76% … +3.36% |
| static | +0.63% | 0.44 | +1.44 | −0.38% … +1.64% |
| stacks | −0.41% | 0.70 | −0.58 | −2.03% … +1.21% |
| mark | +1.27% | 1.05 | +1.20 | −1.16% … +3.70% |
| pause | +1.05% | 0.87 | +1.21 | −0.96% … +3.06% |
| **roots+static+stacks+mark** | **+1.11%** | **0.76** | **+1.47** | **−0.63% … +2.85%** |

Nothing is significant. The bound is ±1.7pp — no tighter than the ±1.5pp the
throughput harness gave.

**The ~0.3% SEM the instrument was supposed to deliver is a pseudo-replication
artifact.** Pooling 1689 collections does give SEM ≈ 0.28%, but collections
within a rep are not independent samples: they share one server process, one
heap layout, one CPU placement. The unit of replication is the rep, n = 9, and
per-rep medians scatter 2–3% (rep 5 roots +6.6%, rep 8 −2.6%). More collections
per rep buy nothing; only more reps do.

So this instrument does not escape the spread that limits the throughput
harness. It measures a different quantity, more directly — it does not measure
it on a quieter host.

**Clue for the residual-spread item, and it kills the standing hypothesis.**
That per-rep scatter (roots sd ≈ 2.7%) is the same magnitude as the
unattributed per-round throughput spread. It shows up here in the collector's
own `monotonic_ns` phase timings, with no wrk in the loop and no clock involved,
so **it is not the load generator and not the timing path** — it is something
per-process.

It is also **not CCD/L3 placement, at least not here**. The standing hypothesis
was that the 9950X's two CCDs let a single-threaded server migrate across an L3
boundary. This host is an **i3-12100F: 4 cores, 8 threads, one 12 MiB L3
instance shared by every CPU**. There is no boundary to cross, and the spread is
present anyway. Either the two hosts have different causes, or the CCD
explanation is wrong for both.

## Post-GC RSS: +1.63%, and this one *is* significant

| | reps | median |
|---|---|---:|
| branch | 12608 12676 12576 12744 12812 12668 12548 12776 12776 | 12676 KiB |
| master | 12344 12412 12556 12368 12704 12180 12340 12656 12808 | 12412 KiB |

Paired: **+1.63%, SEM 0.46, t = 3.59, 95% CI +0.58% … +2.68%.**

264 KiB. Two candidate explanations, one dead:

- **Binary size — no.** The branch binary is 8 KiB larger (text +4.6 KiB,
  bss +3.4 KiB). Off by 30×.
- **Allocator granularity — plausible, unproven.** Linux `small_chunk_bytes` is
  128 KiB, so 264 KiB is ~2 chunks. A slightly different allocation order
  retaining two more size-class chunks would produce exactly this and would not
  be a leak.

The default-path *semantics* are unchanged: both new flags
(`scan_unaligned_candidates`, `allow_interior_pointers`) default to false, so
the guarded expressions evaluate identically to master's. That makes a genuine
retention difference unlikely and the granularity explanation the more probable
one — but it is currently an argument, not a measurement.

**Standing claim:** the branch is throughput- and pause-neutral on the default
path within ±1.7pp, and carries a small, reproducible +1.6% post-GC RSS that is
most likely two chunks of allocator granularity. The earlier "+0.12%, 95% CI
−1.42%…+1.66%" from the throughput harness stands unchanged; this run neither
tightens nor contradicts it.

## Method note

This was the first real use of `key@binary` in `root_phase_ab.sh`, and it
tripped the stale-binary check added the day before: `master` has no `soundness`
field in `/gc-stats`, which is exactly the signature of the stale acik binary
that check was written to catch. A `key@binary` row is a different build by
construction, so those rows are now exempt and say so in the output; rows that
are supposed to be this checkout — including every `BENCH_SERVER_BIN` fat-app
row — are still checked.
