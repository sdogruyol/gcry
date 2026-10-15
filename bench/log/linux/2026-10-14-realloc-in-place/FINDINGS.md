# `realloc` grows a large block in place

ROADMAP "Large `realloc` growth maps, faults and copies every step": Revcomp's
buffers double from 64 KiB to 126 MiB, each step a fresh mapping, faults and a
copy (`../2026-10-04-revcomp-large-realloc/`). Moving pages instead
(`GCRY_REALLOC_MOVE=1`) invalidates the old pointer, which the stdlib reads
after it grows (`process_spec/regression/30_*`).

## Design

A growth that has to copy reserves address space past the block it copies
into: one page plus the data rounded up to a power of two, doubled once
(`LARGE_RESERVE_DOUBLINGS = 1`), `PROT_NONE` with the front made RW
(`MEM_RESERVE` + `MEM_COMMIT` on Windows). The extent is a 6-bit log2 in the
large chunk's flag bits 16–21. The next growth commits pages there and
returns the same pointer. Only realloc growth reserves, only from 256 KiB,
and not under a finite `RLIMIT_AS`. The unused tail is released when the
block dies (`link_free_large`, `destroy`, failure paths), so every cache,
trim, recycle, guard, quarantine and unmap path still sees exactly
`mapped_bytes`. Growth falls back to copying with a barrier armed, during an
incremental mark, with the world stopped, on a thread the stop does not
signal, or when the commit fails (overcommit=2).

## Numbers

`ab.py` + `vmpeak.c` (LD_PRELOAD destructor printing VmPeak). crystal-metric
`--release`, master `b18d5c8`, the branch, the same branch binary with
`GCRY_REALLOC_IN_PLACE=0`, Boehm; 5 interleaved process-fresh trials, medians,
12 vCPUs, each run under a host-wide lock (`final.txt`, `final-raw.json`).

| bench | arm | bench s | RSS MiB | minflt | VmPeak MiB |
|---|---|---:|---:|---:|---:|
| Revcomp | Boehm | 0.494 | 824 | 210.7k | 1038 |
| | master | 0.584 | 560 | 286.9k | 842 |
| | branch | 0.575 | 527 | 266.2k | 843 |
| | branch, off | 0.585 | 560 | 286.9k | 842 |
| JsonParseSerializable | Boehm | 0.263 | 573 | 146.2k | 846 |
| | master | 0.289 | 498 | 186.5k | 825 |
| | branch | 0.297 | 412 | 139.4k | 746 |
| | branch, off | 0.303 | 496 | 183.8k | 823 |
| JsonParsePull | Boehm | 0.258 | 524 | 133.7k | 816 |
| | master | 0.278 | 497 | 173.2k | 828 |
| | branch | 0.291 | 410 | 131.1k | 737 |
| | branch, off | 0.288 | 496 | 173.1k | 823 |
| JsonGenerate | Boehm | 0.632 | 1247 | 319.0k | 1647 |
| | master | 0.612 | 856 | 362.3k | 1221 |
| | branch | 0.598 | 772 | 293.4k | 1665 |
| | branch, off | 0.601 | 856 | 362.5k | 1221 |

- **What it buys:** peak RSS −6% (Revcomp), −17% (both JSON parse rows),
  −10% (JsonGenerate); minor faults −7%, −25%, −24%, −19%. The JSON rows now
  fault less than Boehm.
- **Time:** the feature itself (one binary, on against off) moves the
  benchmark line within its spread: Revcomp −1.7%, JsonParseSerializable −2%,
  JsonParsePull +1% (9-trial recheck, `final-json9.txt`), JsonGenerate −0.5%.
  The JSON parse rows read 3–5% slower than master with the feature off as
  well, and rows the change does not touch move −6% to +3% between the two
  builds, Brainfuck (no allocation) included (`placement.txt`): a build
  difference, not the feature. Whole-process wall on the JSON rows is −4%,
  since their setup builds the input through `IO::Memory`.
- **Sizing** (`sweep-*.txt`, temporary knobs since removed): three doublings
  bought 0–6% fewer faults and 4% on JsonGenerate for 1.5–1.9× the address
  space; two lost Revcomp's RSS gain (its last copy falls at 128 MiB); four
  reached 5.2 GB VmPeak on JsonGenerate. Rounding the whole mapping to a
  power of two cost 130–518 MiB more address space for the same faults. A
  minimum of 64 KiB, 256 KiB or 1 MiB moved no row beyond its spread.

## Gates

- `process_spec/regression/66_realloc_grows_large_in_place_spec.cr`: fails 3
  of 3 on master and with `GCRY_REALLOC_IN_PLACE=0`, passes 3 of 3 on the
  branch. With `grow_large_size` removed, the "old pointer is the grown block"
  and "referents survive collections" examples fail.
- `spec/heap_spec.cr`: room not released at death or destroy → 4 failures;
  stale-byte clear removed → 2; radix retraction removed → the
  `chunk_radix_spec` example fails.
- `make realloc-move-stress` gains an in-place arm: 120 growths in place per
  child under ~190–200 concurrent collections, 0 of 3 failed.

## Not measured

Native macOS and Windows runs (cross-compiled only; CI runs the specs there),
Kemal and acikturkiye. Each reserved chunk is two VMAs instead of one.
