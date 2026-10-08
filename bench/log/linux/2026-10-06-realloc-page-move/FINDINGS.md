# Page faults on allocation storms: where they come from, and moving pages on `realloc`

**Off by default since the merge review** (`GCRY_REALLOC_MOVE=1` turns it
on). The old block reads zeroes after a move, and Crystal's stdlib reads it:
`IO::Memory#write` of its own `to_slice` copies from the old block after
growing, and a 300 KiB self-copy got 303 152 of 307 200 bytes wrong. The
measurements below hold for the opt-in; what the default gives up is in
`../2026-10-06-heap-review/`.

Host: QEMU x86-64 guest, 12 vCPUs shared with two other agents, every build
and run under `taskset -c 4-7` (gcry counts 4 CPUs, so 2 mark workers),
Crystal 1.21.0, Linux 7.0, crystal-metric `--release`. Base is `readiness`
at `7d2c7b3`. A/B runs are `../2026-10-05-alloc-storm-mark/ab.py`: one fresh
process per arm, bench and trial, arm order shuffled, medians with min/max.
`perf` is not permitted here; phase splits come from a copy of `metric.cr`
that prints `getrusage` deltas (minor faults, user, sys, wall) at four points:
process start, after the benchmark's constructor (setup), after the pre-run
`GC.collect`, and after `run` (the timed window). Large mappings per phase
come from `GCRY_TRACE_LARGE=1`.

## Where the faults come from (base)

| | phase | Boehm minflt | gcry minflt | gcry large maps |
|---|---|---|---|---|
| JsonParseSerializable | setup | 126k | 172k | 43, 505 MiB |
| | run | 16.2k | 36.1k | 29, 105 MiB |
| JsonParsePure | setup | 98–105k | 124k | 41, 323 MiB |
| | run | 71–76k | 103–113k | 26, 56 MiB |
| JsonGenerate | setup | — | 210k | 32, 345 MiB |
| | run | — | 108k | 15, 512 MiB |

- JsonParseSerializable's run is one `Array(Coordinate)` growing to 800 000
  elements: 29 `realloc`s, ×1.25 a step, 32 KiB → 22 MiB. Each lands in a
  fresh large mapping that the copy faults in page by page: 105 MiB, about
  27k of the run's 36k faults. Boehm's `GC_realloc` copies too, but into
  heap blocks the setup left resident (its heap never shrank): 16k faults.
  gcry's sys time in the window is 0.030–0.046 s against Boehm's 0.007–0.012.
- JsonGenerate doubles an `IO::Memory` to 256 MiB: 512 MiB of fresh large
  mappings in the window.
- JsonParsePure's run faults are mostly small-chunk refills (JSON::Any
  hashes, arrays, strings) across 7 collections; its large growth is 56 MiB.
  Boehm faults 71–76k there too (its heap grows 565 → 690 MiB in the run).
  Its gap to Boehm is the mark (`../2026-10-05-alloc-storm-mark/`).
- Every setup phase is dominated by the same `realloc` chains (the JSON text
  is an `IO::Memory` grown by doubling, then copied to a `String`).

So the fault gap is not memory the pre-run collection released (the earlier
finding measured that: not releasing it moved JsonParseSerializable 35.8k →
35.2k). It is growth: every growth step faults a new mapping as large as the
buffer.

## The change: grow by moving pages (`Heap#move_large_contents`)

`realloc` of a large block whose data pages hold at least 256 KiB hands those
pages to the new block with `mremap` instead of copying them. No copy, no
fault, and the old pages leave the resident set at the moment of the growth
instead of at the next sweep.

### Designs tried on the way

1. **Prototype: one `mremap(MREMAP_DONTUNMAP | MREMAP_FIXED)` of the old data
   pages into the middle of the new chunk.** Both chunks stay mapped and
   registered and the move is one system call, so it needs no other
   protection. Faults and time (`ab-prototype/`, 5 trials, `PROTO_MOVE=1`):
   JsonParseSerializable run 36.1k → 14.5k faults, 0.341 → 0.324 s;
   JsonGenerate 108k → 42k, 0.709 → 0.639 s, peak RSS 856 → 764 MiB;
   JsonParsePure 102.5k → 91k. But the moved pages stay their own kernel
   mapping (VMA) inside the destination, and do not merge with the fresh
   tail around them (their page offset is that of their first mapping). Each
   growth adds one: `vma_split.c` / `vma_split.txt` show 3, 4, 5, 6 VMAs for
   one buffer over four growths. `vm.max_map_count` (65 530) is process-wide,
   and when it is reached every later `mmap` fails. And before Linux 6.17 a
   move whose source spans two VMAs is refused with `EFAULT` *after* the
   kernel has unmapped the destination, which leaves a hole in a registered
   chunk.
2. **The prototype with a cap**: a 3-bit "VMA pieces" count in the large
   chunk's flags, a source at 4 pieces copied into a fresh chunk instead.
   Bounded, but every fourth growth copies again: JsonParseSerializable's
   run faults came out at 24.1k instead of 14.5k, JsonGenerate 86k instead
   of 42k. Dropped.
3. **Shipped: staged.** `MREMAP_DONTUNMAP` without a fixed destination (the
   kernel picks an address; the old range stays mapped and reads zeroes),
   then a plain `MREMAP_MAYMOVE | MREMAP_FIXED` move from that address into
   the new chunk's data range *with the growth*, so the data is one mapping
   again however often a block grows (`vma_count.cr`: 200 arrays grown to
   400 000 elements hold 2.04 mappings each, header page plus data; copied,
   adjacent fresh chunks merge and they hold 0.32). Same faults as the
   prototype (JsonParseSerializable 14.5k, JsonGenerate 42k).

   Between the two calls the contents are in neither chunk. A collection
   that stopped the thread there would mark through neither and free what
   only those pages reach. The stop signal is blocked across the two calls;
   nothing in between takes a lock, so a stop that asks waits two system
   calls for this thread. `make realloc-move-stress` (three threads growing
   `Array(Parcel)` to 400 000 elements, a fourth calling `GC.collect` every
   millisecond, every parcel checked): default 0 of 3 children lose one,
   396 moves under ~500 collections; with the signal left unblocked and the
   window held 200 µs (`GCRY_REALLOC_MOVE_TEST_UNBLOCKED_US=200`) 11 of 12
   rounds lose parcels (23 of 24 with 8 rounds per child).

### What the move refuses

- Old data under 256 KiB (`Heap::REALLOC_MOVE_MIN`, below).
- A page barrier armed (nursery, incremental mark), `@incremental_marking`,
  or a stopped world: there a new block is black and never scanned, so its
  contents must arrive where the mark looks — the copy leaves them in the
  old block, a move would not.
- A thread the stop does not signal (Monitor, idle collector, a thread not
  yet on Crystal's list): the world could stop around the window.
- `vm.overcommit_memory = 2`: the second call charges the growth after it
  has unmapped the destination, and a charge that loses a race for the
  commit limit would leave a hole. Under the other modes it cannot fail for
  memory the destination already held.
- A kernel without `MREMAP_DONTUNMAP` (before 5.7): the first call answers
  `EINVAL` before touching anything, and moves turn off for the process.
- If the second call is refused anyway, the destination is mapped again
  with `MAP_FIXED_NOREPLACE` (`EEXIST`: still there) and the contents are
  copied from the kernel's address; a destination that cannot be mapped
  again aborts with a message rather than leave a chunk pointing at nothing.

What changes for a program: a reader that kept the pre-`realloc` pointer
reads zeroes where the copy left the old bytes until the sweep. Boehm frees
that block inside `GC_realloc`, so that reader was already reading memory
the collector could hand out again.

### The threshold

Each `mremap` flushes the TLB of every CPU the process runs on, so a move
costs more when other threads are busy. `realloc_growth.cr` grows an
`IO::Memory` by 1 KiB writes; `threshold-sweep.txt` has the runs. With three
threads spinning beside it, moving from 64 KiB on was +10% against copying
at 512 KiB; from 256 KiB on it was ±1% there, −9% at 1 MiB and −32% at 4 MiB.
Alone, every size gains (256 KiB on: −15%, −28%, −46%). 256 KiB it is.

## Result (`ab-final/`, 7 trials; `ab-json15/`, 15 trials for the two JSON parse rows)

Speed is Boehm's median over gcry's; RSS is median peak RSS.

| bench | Boehm | base | new | speed base → new | RSS MiB Boehm / base / new |
|---|---|---|---|---|---|
| Primes | 0.712 s | 0.962 (0.933–1.012) | 0.978 (0.933–1.015) | 74.0% → 72.8% | 659 / 595 / 595 |
| JsonParsePure (15) | 0.365 | 0.501 (0.483–0.571) | 0.494 (0.482–0.503) | 72.9% → 73.9% | 689 / 543 / 534 |
| JsonParseSerializable (15) | 0.270 | 0.297 (0.290–0.321) | 0.279 (0.269–0.313) | 90.9% → 96.8% | 556 / 437 / 385 |
| JsonGenerate | 0.647 | 0.610 (0.600–0.621) | 0.567 (0.554–0.581) | 106% → 114% | 1200 / 856 / 764 |
| Binarytrees | 0.533 | 0.621 (0.614–0.638) | 0.619 (0.614–0.627) | 85.8% → 86.1% | 51 / 22 / 22 |
| RegexDna | 1.746 | 1.746 (1.720–1.774) | 1.741 (1.706–1.796) | 100% → 100% | 513 / 272 / 272 |
| Revcomp | 0.504 | 0.585 (0.572–0.590) | 0.558 (0.544–0.568) | 86.2% → 90.3% | 960 / 560 / 509 |

- JsonParseSerializable: 13 of 15 new runs are faster than base's fastest.
  In the 7-trial runs it read 0.300 → 0.284 (`ab-first/`) and 0.307 → 0.305
  with base's max at 0.361 (`ab-final/`): the host is shared and this row is
  0.3 s long, so it got the 15-trial run.
- JsonGenerate and Revcomp: every new run is faster than every base run in
  both 7-trial runs.
- Primes, JsonParsePure, Binarytrees, RegexDna: within the spread both ways
  (Primes +1.7% here, −2.9% in `ab-first/`).
- Peak RSS never rises: −12% JsonParseSerializable, −11% JsonGenerate, −9%
  Revcomp, −2% JsonParsePure.
- Result lines are identical across Boehm, base and new on every row (the
  JSON, RegexDna and Revcomp rows print `err` with the same values for all
  three, Boehm included; that predates this change).

Minor faults, same binary with `GCRY_REALLOC_MOVE=0` / default (setup / run):

| | copy | move |
|---|---|---|
| JsonParseSerializable | 171.6k / 36.1k | 103.1k / 14.7k |
| JsonParsePure | 124.1k / 113.1k | 79.2k / 91.3k |
| JsonGenerate | 210.3k / 107.8k | 139.9k / 42.3k |
| Revcomp | 114.6k / 209.3k | 81.9k / 160.2k |
| RegexDna | 101.1k / 52.4k | 68.5k / 37.7k |

## Not done, and why

- **Carving size-class chunks out of freed large mappings / a shared page
  arena.** The faults the brief attributed to this are growth faults (above),
  which moving removes at the source; after a move the old block's pages
  are already gone, so there is nothing resident left to carve.
- **Keeping memory warm across the explicit pre-run `GC.collect`.** Measured
  in `../2026-10-05-alloc-storm-mark/`: JsonParseSerializable 35.8k → 35.2k
  faults, wall unchanged. Not repeated.
- **MADV_FREE instead of DONTNEED for released chunks.** Not measured: the
  faults left on JsonParsePure are first touches of small-chunk refills
  (`MADV_POPULATE_WRITE` already batches them past 32 MiB), and the empty
  chunks of an explicit collection are unmapped, not madvised, on the Linux
  process default (`empty_chunk_retain = 0`).

## Gates (this tree, `taskset -c 4-7`)

`crystal tool format --check`, `make lint`, `ci/knob-doc-check.sh`,
`crystal spec` (294), `crystal spec -Dgc_none process_spec` (78), with
`-Dgcry_block_headers` (78), and with `GCRY_BITMAP_ALLOC=0` (78);
`make parallel-mark-stress mark-audit parallel-mark-termination
thread-death-window interior-only-buffer unaligned-only-buffer
finalizer-complex realloc-move-stress idle-rss-after-burst idle-release
large-cache-race large-freelist-madvise rss-leak released-range-report
kept-release-report live-graph-audit darwin-typecheck windows-typecheck`, and
an aarch64-linux cross type-check. `idle-rss-after-burst` failed once
("the burst was still live 21 majors after it was dropped", the harness's
own no-test verdict) while other gates were compiling; then 0 of 20 on this
tree and 1 of 20 on base.
