# Per-thread mark cost: candidates resolved in the scan loop, whole payloads prefetched

Host: QEMU x86-64 guest, 12 vCPUs, Crystal 1.21.0, crystal-metric `--release`,
every process fresh. **Every build and run was under `taskset -c 0-3`**, so
gcry counts 4 CPUs and its default is 2 mark workers, not the 4 it picks on
the whole host. Base is `readiness` `7d2c7b3`. Three agents shared the host,
which is why absolute numbers drift between sessions. Only interleaved arms
are compared.

Tools in this directory:

- `marksum.py` interleaves arms and starts a fresh process per run. It sums
  `mark_ns` and `pause_ns` over every `collect_end` event of `GCRY_TRACE=1`
  (alloc sampling off) and records the bench's own wall time.
- `boehmmark.py` sums Boehm's "World-stopped marking took" lines under
  `GC_PRINT_STATS=1 GC_MARKERS=1`.
- `../2026-10-05-alloc-storm-mark/ab.py` gives wall time, CPU and peak RSS
  (`ab-final-*`).
- `sampler.c` is the SIGPROF sampler from `../2026-10-03-monitor-wait-spin/`,
  changed to `mmap` its buffer (see below). `pcprof.py` turns samples into
  per-function and per-instruction counts.
- `candidate-counters.patch` with `main_prof.cr` (`-Dgcry_markprof`) counts
  per-candidate outcomes. `shadow-check.patch` with `main_shadow.cr`
  (`-Dgcry_inline_shadow`) is the equivalence check. To build either:
  `CRYSTAL_PATH=<bench/crystal_metric/lib>:$(crystal env CRYSTAL_PATH)`.

## The sampler was profiling its own buffer

The 2026-10-03 sampler stores samples in two static 4 Mi-entry arrays, 64 MiB
of BSS. Preloaded, that BSS is a writable segment, and gcry scans those as
static roots on every collection. On JsonParsePure (current code, one marker)
about 11% of samples were that scan: `run_collection_body`'s static-range
loop, plus `mark_impl_unlocked` rejecting the words. The trace's `static_ns`
is under 0.15 ms per collection without the sampler. The copy here `mmap`s
its buffer.

Profiles taken with the old sampler include this cost. For base it is a few
points: `mark_impl_unlocked` is 23–27% of samples with either sampler.

## Where one marker's time went (base)

Fixed sampler, 3 runs, share of all samples:

| | Primes | JsonParsePure |
|---|---|---|
| `mark_impl_unlocked` | 23.5% | 27.3% |
| `scan_object` (inlined `scan_payload`) | 22.6% | 17.0% |
| `mark_loop` (prefetch ring) | 7.0% | 3.7% |
| `UInt64@Int#>>` (radix shift, out of line) | 1.8% | — |

Candidate outcomes, whole process, one marker (`candidate-counters.patch`):

| bench | words scanned | objects scanned | candidates | already marked | new, atomic | pushed | no chunk | large |
|---|---|---|---|---|---|---|---|---|
| Primes | 255.8 M | 38.4 M | 38.4 M | 871 | 389 | 38.4 M | 169 | 53 |
| JsonParsePure | 341.3 M | 26.6 M | 52.8 M | 19.2 M | 6.9 M | 26.6 M | 333 | 120 |
| JsonParseSerializable | 145.1 M | 11.2 M | 16.9 M | 1 406 | 5.6 M | 11.2 M | 305 | 104 |
| JsonGenerate | 602.5 M | 43.2 M | 85.8 M | 20.9 M | 21.6 M | 43.2 M | 377 | 117 |
| Binarytrees | 33.7 M | 7.9 M | 7.9 M | 16 K | 7.8 K | 7.8 M | 3.6 K | 780 |

No candidate in any bench pointed at a free block. Rejection is not where
the time goes: under 400 candidates per run fall outside the chunk table. On
Primes almost every candidate is the first mark of a new object. On
JsonParsePure and JsonGenerate a third are already marked.

So one marker spent about 20 ns per object on Primes (774 ms / 38.4 M) and
28 ns on JsonParsePure. Boehm with one marker spends 378 and 394 ms.

`mark_impl_unlocked` in the disassembly:

- `report_thread_list_offer` is inlined into it, so the function pushes six
  callee-saved registers and opens a 504-byte frame on every call.
- The radix shift by `@radix_granule_shift` compiles to an out-of-line call
  to `Int#>>`.
- Crystal emits no alias information, so every `self` field and chunk field
  is reloaded after each store. The block ordinal is derived three times,
  for `block_allocated?`, `block_marked_in?` and `set_block_mark_in`, each
  with a checked conversion, a checked multiply and a bounds-checked table
  read.
- Each candidate stores to `@radix_fast_hits`.
- The push ends in a tail call to `MarkStack#push`.

Boehm's `PUSH_CONTENTS` does a header-cache lookup, a map lookup and a
mark-byte test-and-set, all inline.

## Changes

1. **`scan_edges_inline`** (`mark: resolve heap edges in the scan loop`).
   - Inside `mark_loop`, with the world stopped and under `bitmap_alloc`,
     `scan_payload` resolves each in-span word itself.
   - The radix table and heap bounds are loaded into registers once per
     payload.
   - The ordinal is derived once. The mark bit is read before `occ`, and
     the mark is set with one atomic OR.
   - Anything unusual goes to `mark_impl`, which stays the authority: no
     table entry, a large or nursery chunk, an address outside the blocks.
   - `Heap.radix_entry` shifts with `unsafe_shr`, and `radix_lookup` now
     uses it too.
2. **`prefetch_mark_entry`** (`mark: prefetch a small block's whole
   payload`).
   - The serial ring and the parallel batch scan prefetch every line of a
     tagged entry's block, up to 256 bytes, instead of the first line.

## Results

One marker (`GCRY_PARALLEL_MARK=1`), Σ mark over the whole process, 7
interleaved runs, median (min–max) in ms. Data: `serial-mark.txt`,
`boehm-one-marker.txt`.

| bench | base | + inline edges | + payload prefetch | Boehm, 1 marker |
|---|---|---|---|---|
| Primes | 774 (745–798) | 592 (566–599) | **493** (477–512) | 378 |
| JsonParsePure | 744 (732–766) | 498 (470–518) | **392** (378–503) | 394 |
| JsonParseSerializable | 214 (210–226) | 141 (136–146) | 142 (139–148) | 178 |
| JsonGenerate | 812 (808–823) | 540 (527–552) | 553 (541–565) | 357 |
| Binarytrees | 104 (103–110) | 70 (69–75) | 75 (73–75) | 35 |

Wall time with one marker: Primes 1.38 → 1.10 s, JsonParsePure 0.72 → 0.53 s
(Boehm with one marker: 0.97 and 0.42).

Default workers (2 under this affinity), `ab.py`, 7 interleaved runs.
Median wall time in seconds; peak RSS in MiB. Data: `ab-final-summary.txt`,
`ab-final-raw.json`.

| bench | Boehm | base | inline | new | speed × Boehm, base → new | RSS: Boehm / base / new |
|---|---|---|---|---|---|---|
| Primes | 0.695 | 0.969 | 0.878 | **0.859** | 71.7% → 80.9% | 659 / 595 / 595 |
| JsonParsePure | 0.368 | 0.510 | 0.447 | **0.435** | 72.2% → 84.6% | 688 / 543 / 543 |
| JsonParseSerializable | 0.270 | 0.299 | 0.298 | 0.295 | 90.3% → 91.5% | 541 / 437 / 437 |
| JsonGenerate | 0.640 | 0.607 | 0.610 | 0.604 | 105% → 106% | 1303 / 856 / 856 |
| Binarytrees | 0.525 | 0.619 | 0.585 | **0.589** | 84.8% → 89.1% | 51 / 22 / 22 |
| RegexDna | 1.721 | 1.748 | 1.739 | 1.740 | 98.5% → 98.9% | 513 / 272 / 272 |
| Revcomp | 0.499 | 0.579 | 0.581 | 0.586 | 86.2% → 85.2% | 822 / 560 / 560 |

- Primes, JsonParsePure and Binarytrees: every new run is faster than every
  base run.
- The other four rows overlap base within min–max: Revcomp 0.572–0.593
  against 0.577–0.599, and Revcomp marks almost nothing (2 K candidates per
  run).
- Peak RSS is identical on every row.
- CPU (user + sys): Primes 1.41 → 1.17 s, JsonParsePure 1.49 → 1.22,
  JsonGenerate 2.49 → 2.20.

Per thread, gcry's mark now matches Boehm on JsonParsePure and beats it on
JsonParseSerializable. It is 1.30× Boehm on Primes, 1.55× on JsonGenerate
and 2.1× on Binarytrees.

## Where the time goes now (Primes, one marker)

- `scan_edges_inline` is 27% of samples, the drain 11% and `scan_object` 5%.
- In `scan_edges_inline`, 12% of its samples sit on the instruction after
  the mark bit's `lock or`. That is the wait for the `occ` and mark-word
  loads before it. The radix slot and chunk-header loads take 6–8% each.
- The drain's samples sit on its prefetch instructions, with the fill
  buffers full.

What is left is mostly memory-level parallelism, not instructions. Each
first mark touches the radix slot, the chunk header, an `occ` word and a mark
word, which is one more line than Boehm's header and mark byte.

Binarytrees is not a mark problem: `malloc` is 60% of its samples. 22% of
all its samples are on the cursor's `occ` `lock or`, after the sequentially
consistent fence in `fast_alloc` (heap.cr:1107–1124).

## Tried and dropped

- **Radix `unsafe_shr` alone**, without the inline path: Σ mark within
  noise, 5 runs (Primes 820 → 836 ms, JsonParsePure 778 → 776). It is kept
  only as the shift of the shared `radix_entry`.
- **Plain mark-bit store when serial** (`@mark_parallel` false): no change,
  5 runs (Primes 515 → 517 ms, JsonParsePure 408 → 401). This agrees with
  2026-10-05.
- **`@[AlwaysInline]` on `scan_edges_inline`** (into `scan_object` and
  `scan_large_from`): Primes +4%, JsonParsePure +2%.
- **Prefetch ring depth**, 5 runs against 16: at 8, Primes +9% and
  JsonParsePure +5%. At 32, Primes −4% and JsonParsePure +2%. Left at 16.
- **Prefetch cap**, 3 runs, JsonParsePure: 488 ms at 64 bytes, 457 ms at 128,
  403 ms at 256, 430 ms at 512, 403 ms at 1 KiB. Primes was flat.
- **Fixed prefetches instead of the loop**, 7 runs
  (`serial-mark-prefetch-variants.txt`):
  - first and last line: JsonParsePure 514 ms;
  - three lines: 436 ms;
  - the loop: 403 ms.
  Both variants were also worse than the loop on Binarytrees and
  JsonGenerate.
- **The loop's cost on small objects**: against the inline-only build,
  Binarytrees +2–7%, JsonGenerate +2–7% and JsonParseSerializable +1–4%
  across two sessions. That is at the edge of their spread, and their wall
  time did not move.

## Correctness

- **Shadow check** (`shadow-check.patch`, one marker). For every candidate
  the inline path handled, the build re-derived the old path's decision
  without side effects: `find_block_with_chunk`, `block_allocated?`, the
  base-only test and the mark bit before the write. It then checked the
  mark bit and mark-stack top afterwards. Result: 183.7 M decisions across
  Binarytrees, Primes, JsonParsePure, JsonParseSerializable, JsonGenerate,
  RegexDna, Revcomp, Knuckeotide and Threadring, **0 mismatches**.
- **`live_objects` per collection, inline on against off in one binary**
  (temporary switch, `livediff.py`):
  - Binarytrees (259 collections) and JsonParseSerializable: identical.
  - Primes: 1 of 13 collections differs by +5. Two runs of the base binary
    differ by +34 there.
  - JsonParsePure and JsonGenerate also differ run to run with the same
    binary (±1, and once +90 K on JsonGenerate), so their comparison is not
    informative.
  - Base against new differs on Binarytrees because the collector's own
    stack frames change between binaries. The same binary is identical with
    the path on or off.
- **Gates, on each commit's tree, all under `taskset -c 0-3`:**
  - `crystal tool format --check src spec process_spec bench`, `make lint`,
    `ci/knob-doc-check.sh`;
  - `crystal spec` (293 examples);
  - `crystal spec -Dgc_none process_spec` (78), the same with
    `-Dgcry_block_headers` (78), and again with `GCRY_BITMAP_ALLOC=0` (78);
  - `make parallel-mark-stress mark-audit parallel-mark-termination
    thread-death-window interior-only-buffer unaligned-only-buffer
    finalizer-complex parallel-mark-process stw-index-race darwin-typecheck
    windows-typecheck`.

  All green. `mark-audit`'s planted miss is applied in `scan_payload` before
  the inline branch, so its red arm still drops an edge on the new path.
