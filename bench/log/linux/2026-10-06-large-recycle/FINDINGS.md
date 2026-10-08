# Large-object recycling: finishing `large-recycle.patch`

Host: the 12-vCPU QEMU guest, Linux 7.0, Crystal 1.21.0, crystal-metric
`--release`, process-fresh, every run under `taskset -c 0-7`. Base is
`readiness` at `ac3d559` plus `../2026-10-06-mutator-gap/large-recycle.patch`.
A/B harness `../2026-10-05-alloc-storm-mark/ab.py`; every gcry comparison
here is one binary with `GCRY_LARGE_RECYCLE=0` as the control, because code
placement moves rows ±6% between builds (`../2026-10-06-mutator-gap/`).

The prototype left three questions: a Primes slowdown, a bimodal Revcomp peak
RSS and RegexDna's RSS. Each had a cause in the recycler; two needed a change.

## Revcomp's high peak: an address the recycler handed back

`root-trace.patch` prints every stack/thread root that lands in a large chunk
(`GCRY_TRACE_LARGE=1`); `root-hits.py` sorts a run's hits. Prototype, 20 runs
per arm, one binary:

- 5 of 20 runs with recycling peak at 588 MiB (others 526). In all five, and
  in none of the other 35 runs, a main-fiber stack slot holds the exact base
  of the third iteration's `seq.to_s` string (65 MB) at collections 16 and
  17, so it survives past its use.
- The allocation sequence of a high run and a low run is identical, recycled
  sizes included. The difference is where the 65 MB string landed: in all
  five high runs the recycler grew the second iteration's 39 MB chunk by
  `mremap(MREMAP_MAYMOVE)` *in place*, so the new string started at the
  dead one's address. In every low run the kernel had moved it. The stale
  slot held the second string's address; it named the third.
- Reusing a chunk's front has the same effect whenever an exact pointer to
  the dead block is left anywhere.

Fix: the recycled pages move to a fresh mapping at an address the kernel
picks: `mmap` a destination, then `mremap(MREMAP_MAYMOVE | MREMAP_FIXED)`
onto it (`Gcry.os_move`). Page tables only, nothing copied or faulted; a
split moves the front and leaves the remainder cached where it was; an exact
fit is moved too (the exact-size cache is skipped under recycling). Same 20
runs: no 588-mode run.

The other high runs are older than recycling and appear in both arms:
2 of 20 with the prototype off, 1-3 of 24-30 per arm on the final tree, at
564 or 652 MiB. Their roots are words of the form `0xHHHH_0000_00xx`: a
stale pointer whose low half a 32-bit store overwrote. They retain whatever
large chunk straddles that 4 GiB boundary: the setup's 128 MiB `IO::Memory`
buffer or `@input`, both allocated before the first recycle. Whether a
chunk straddles the boundary depends on ASLR.

Peak RSS of Revcomp, final tree (`ab-15`, `ab-rp`, and a 24-run loop):
recycling on 4 of 54 runs above 540 MiB, off 4 of 54.

## Primes: the pace timed the unmap

Prototype: Primes median unchanged, but off had a fast mode (0.565-0.606 s,
17 of 45 trials) that on almost never reached (4 of 45). `GCRY_TRACE=1`
(`pace.py`):

- The fast runs have 5 majors in the timed run, the slow 6. The split is
  decided at collection 4, whose pace sets the threshold: off 170-237%,
  on 127-193%.
- Collection 4 frees the dead 40 MB sieve. Off, the flush unmaps it inside
  the cycle (1.2-1.5 ms of a 5-7 ms cycle). On, the major keeps it; nothing
  large is allocated afterwards, so the budget unmaps it from the
  mutator's `allocate` instead. The pace divides the cycle time by the
  mutator time, so it read the cycle as cheaper and set a lower threshold.
  The heap was then collected earlier at each step and one more major fit
  in the run.
- Control (`primes-pace-prototype-summary.txt`): with
  `GCRY_THRESHOLD_PACE=100` on and off are equal, 0.714 against 0.719 s.

Fix: a major keeps no more than the large bytes allocated since the
previous major and unmaps the rest in the cycle, as without recycling.
Primes has none in that interval, so collection 4 is what it was before.
Final tree, same binary: `ab-rp` 0.596 against 0.595 s with the same spread
and modes; `ab-15` 0.610 both.

This keeps somewhat less for Revcomp. Whole-process minor faults: off
311.5k, keep everything 247k, final 255-256k. A variant that counted only
allocations able to take a cached chunk (not page-moving `realloc`s) and
kept the larger of the last two intervals did worse, 260k, and was dropped.

## RegexDna RSS

The prototype's budget held it to +1.5% (276 against 272 MiB). With the
keep limit the setup's ~200 MB of large frees go back at that major, as
without recycling: 272 MiB in both arms, every trial.

## Final A/B (one binary, `GCRY_LARGE_RECYCLE=0` control, Boehm)

15 trials (`ab-15-summary.txt`) and 9 (`ab-9-summary.txt`). Wall median
(min-max) in seconds, peak RSS median / max in MiB:

| bench | on | off | Boehm |
|---|---|---|---|
| Revcomp | **0.521** (0.512-0.528) 524/527 | 0.533 (0.528-0.543) 526/564 | 0.494 (0.475-0.518) 890 |
| Primes | 0.610 (0.560-0.631) 613/622 | 0.610 (0.576-0.634) 618/622 | 0.608 (0.599-0.619) 659 |
| RegexDna | 1.703 (1.680-1.744) 272/272 | 1.705 (1.688-1.753) 272/272 | 1.693 (1.666-1.733) 397 |
| JsonGenerate | 0.553 (0.545-0.583) 763/763 | 0.555 (0.543-0.594) 763/763 | 0.647 (0.632-0.668) 1228 |
| JsonParseSerializable | 0.274 (0.269-0.287) 421/421 | 0.277 (0.266-0.286) 421/423 | 0.269 (0.261-0.280) 572 |
| JsonParsePure | 0.349 (0.341-0.371) 548 | 0.354 (0.343-0.384) 548 | 0.342 (0.331-0.346) 686 |
| JsonParsePull | 0.269 (0.266-0.278) 408 | 0.274 (0.267-0.279) 421 | 0.258 (0.251-0.284) 540 |
| Binarytrees | 0.544 (0.525-0.551) 38 | 0.540 (0.527-0.557) 38 | 0.510 (0.501-0.515) 51 |
| Knuckeotide | 0.622 (0.613-0.643) 59 | 0.621 (0.617-0.627) 62 | 0.588 (0.581-0.602) 40 |
| Brainfuck | 2.513 (2.453-2.716) 6 | 2.490 (2.457-2.514) 5 | 2.449 (2.404-2.725) 5 |
| Brainfuck2 | 1.124 (1.112-1.133) 5 | 1.126 (1.121-1.139) 5 | 1.124 (1.118-1.923) 5 |
| Matmul | 0.343 (0.341-0.346) 37 | 0.344 (0.341-0.346) 37 | 0.346 (0.344-0.346) 30 |
| Threadring | 0.383 (0.379-0.389) 8 | 0.387 (0.381-0.393) 8 | 0.404 (0.399-0.418) 7 |

- Revcomp: −2.3% here, −3.3% in `ab-rp` (same binary). Pooled 30 trials:
  0.5225 against 0.5375 s (−2.8%), an on-run faster than an off-run in
  96.5% of pairs. 55k fewer page faults.
- No other row moves beyond its spread. Brainfuck's median is +0.9% on a
  row with no large allocation and a 2.45-2.72 s on-arm spread (one slow
  outlier).
- Median peak RSS, on against off: at most +0.5% (Threadring 7.66 against
  7.62 MiB; Brainfuck's 6 against 5 above is 5.51 against 5.49 MiB rounded),
  −3.1% JsonParsePull, −5.2% Knuckeotide.

Kemal `/json` (`kemal-json-summary.txt`, `../2026-10-06-threshold-pacing/kemal_ab.py`,
server on CPUs 8-10, `wrk -t1 -c50 -d10`, 7 trials, one binary): on 45 831
req/s (43.2-47.8k), off 46 264 (43.4-48.2k); peak 22.3 against 22.1 MiB,
after `/gc-collect` 13.9 against 13.7.

## Gates

On the final tree: `crystal tool format --check src spec process_spec
bench`, `make lint` (178 inspected, 0 failures), `ci/knob-doc-check.sh`
(220 knobs), `crystal spec` (297), `crystal spec -Dgc_none process_spec`, the
same with `-Dgcry_block_headers` and with `GCRY_BITMAP_ALLOC=0
-Dgcry_block_headers`, `make parallel-mark-stress mark-audit
parallel-mark-termination thread-death-window interior-only-buffer
unaligned-only-buffer finalizer-complex pause-budget darwin-typecheck
windows-typecheck idle-rss-after-burst idle-release rss-leak
released-range-report kept-release-report large-cache-race
large-freelist-madvise realloc-move-stress`.

The new spec (`spec/heap_spec.cr`, Linux) checks that a recycled block
starts where no dead block did (the freed pointer is no longer a heap
pointer), reads zero, and that a split's remainder and a grown tail are
counted in `large_free_bytes` and `Gcry.os_mapped_bytes`. It fails on the
prototype, which handed the dead block's address back.
