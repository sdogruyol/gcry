# Merge review of `readiness`: the heap items

Host: QEMU x86-64 guest, 12 vCPUs shared with four other agents, every
build and run under `taskset -c 4-7` (gcry counts 4 CPUs, so 2 mark
workers), Crystal 1.21.0, Linux 7.0, `--release`. Base is `readiness` at
`a4c0dbd`. Each finding was reproduced on the base tree before the fix.

## 1. The `realloc` page move corrupted data (now opt-in)

`Heap#move_large_contents` (`../2026-10-06-realloc-page-move/`) hands a
large block's pages to the grown block; the old block keeps reading zeroes
past its first page. Crystal's stdlib reads the old block after `realloc`:
`IO::Memory#write(io.to_slice)` grows `@buffer`, then copies from the slice.

300 KiB `IO::Memory` self-copy, wrong bytes of 307 200:

| | wrong |
|---|---:|
| base, default (move on) | 303 152 |
| base, `GCRY_REALLOC_MOVE=0` | 0 |
| Boehm | 0 |

`process_spec/regression/30_realloc_old_block_readable_spec.cr` on the base
tree: `IO::Memory` 303 152 wrong, `String::Builder#write` of a slice over
its own buffer 303 164, `Array#concat` of a slice over its own buffer
298 988 (of 300 000 elements). Keeping the old block readable while its
pages move would need the two blocks to share pages (`mremap` with an old
size of 0 duplicates only shared mappings), which private anonymous chunks
cannot, so the move is off by default and `GCRY_REALLOC_MOVE=1` turns it on.

What the default gives up, one binary with and without `GCRY_REALLOC_MOVE=1`,
the base binary and Boehm, 11 interleaved process-fresh trials
(`ab-move-summary.txt`, `ab-move-raw.json`). Wall median (min-max) in s,
peak RSS median in MiB:

| bench | copy (default) | move | base | Boehm |
|---|---|---|---|---|
| JsonParseSerializable | 0.338 (0.301-0.360) 491 | 0.321 (0.291-0.361) 416 | 0.312 425 | 0.314 536 |
| JsonGenerate | 0.715 (0.675-0.748) 856 | 0.632 (0.621-0.671) 763 | 0.644 763 | 0.805 1305 |
| Revcomp | 0.656 (0.609-0.678) 562 | 0.613 (0.585-0.648) 515 | 0.621 515 | 0.581 878 |
| RegexDna | 1.992 (1.893-2.138) 272 | 1.981 272 | 1.987 272 | 1.995 454 |

Shipped (copy) against Boehm on 4 CPUs: JsonParseSerializable 93%,
JsonGenerate 113%, Revcomp 89%, RegexDna 100%; peak RSS 0.92×, 0.66×, 0.64×,
0.60×. The move was worth 5%, 12% and 7% of wall on the first three, and
9-15% of their peak RSS.

## 2. Atomic slack overflow

`n = size &+ @atomic_slack` wrapped: on the base tree
`GC.malloc_atomic(SIZE_MAX)` returned a block and `GC.realloc(p, SIZE_MAX)` of
an atomic block returned one holding none of its bytes, where
`GC.malloc(SIZE_MAX)` and `GC.malloc_atomic(SIZE_MAX - 1)` raise
`OverflowError`. Saturating (as Boehm's `SIZET_SAT_ADD`), both raise.
`process_spec/regression/31_alloc_size_edges_spec.cr`.

## 3. Large blocks freed with `GC.free` under recycling

The recycling budget is what the last major left in the cache, and a free
trimmed the cache to it; between majors in a loop that never collects that is
0, so every `GC.free` of a large block unmapped it and the next allocation
mapped and faulted in a fresh one. zlib allocates and frees its stream state
through `GC.malloc`/`GC.free`.

`bench/gzip_free_loop.cr`, 20 000 `Compress::Gzip::Writer` streams of 4 KiB,
7 interleaved runs (`gzip-ab.txt`), median ms:

| | ms (min-max) | unmapped in the loop |
|---|---|---|
| base, default | 793 (752-880) | 5.4 GB, 80 057 chunks mapped |
| base, `GCRY_LARGE_RECYCLE=0` | 345 (327-358) | 1.8 MiB, 84 |
| floor only (cache kept, handed out through the recycler's fresh mapping) | 605-625, 3 runs | 1.8 MiB, 80 057 |
| fixed, default | 344 (303-367) | 1.8 MiB, 85 |
| fixed, `GCRY_LARGE_RECYCLE=0` | 344 (304-356) | 1.8 MiB, 85 |
| Boehm | 957 (830-1036) | — |

A floor on the budget alone (the large-cache retain plus 2 MiB, what the
exact-size cache keeps without recycling) stopped the unmapping, but the
recycler moves even an exact fit to a fresh mapping, an `mmap` and an
`mremap` per allocation, which left the loop at 2× the master behaviour. A
chunk the program freed itself is now flagged (`ChunkHeader::Flags::FREED`)
and taken in place by the next allocation of its exact size, as without
recycling; chunks the sweep freed still go through the fresh mapping, so a
stale word naming a dead block never names its successor.
`process_spec/regression/32_large_free_reuse_spec.cr` (red on the base tree:
26 624 000 and 27 852 800 bytes unmapped) and `make gzip-free-reuse` (red on
the base tree: 544 000 KiB unmapped in 2 000 iterations).

Revcomp and RegexDna peak RSS do not move with this: the move arm of the
fixed binary matches the base binary (515 and 272 MiB, table above).

## 4. `GC_realloc(p, 0)`

Returned `malloc(0)` and left `p` to the sweep. Now frees `p` and returns
null, as Boehm (`mallocx.c`); `realloc(NULL, n)` stays `malloc(n)`, through
`GC.realloc`, `GC_realloc` and `Heap#realloc`.

## 5. `String::Builder` regression under the slack

`process_spec/regression/22_string_builder_terminator_spec.cr` passed on the
base tree with `crystal_string_builder_compat.cr` removed (3 examples, 0
failures): the slack absorbs the terminator by itself. It now sets
`atomic_slack = 0` on the process heap for its examples and restores it;
with the compat patch removed it fails all three (116-byte build, 4-byte
initial capacity, `strlen` 116).
