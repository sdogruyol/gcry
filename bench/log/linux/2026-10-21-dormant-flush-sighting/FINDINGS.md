# The 2026-09-28 `dormant_flush` sighting, re-read (2026-10-21)

The ROADMAP item "a large chunk released with its block still allocated"
(`bench/log/linux/2026-09-28-dormant-flush-large-release/FINDINGS.md`) asked
whether 0.38.0's dormancy bug (an in-stop sweep making a pool chunk dormant
under a frozen taker, 69bd6a2e,
`bench/log/linux/2026-10-21-claim-counter-drift/`) explains it. **It does
not.** Re-reading the one report line that survived also shows the item's
premise was wrong: the chunk was not released with its block allocated. It
was a chunk from the large cache, and the access was to its block header. The
same binary's unsafe control arm reproduces the report line exactly, and
there the access comes from the lazy sweep. Neither that path nor any other
was found open in the default arm, and nothing reproduced in 724 children of
the 2a46123 binary and the patched current tree. Three things were fixed on
the way: the report's occupancy figure, the gate's lost trim traffic, and the
harness dropping the part of the report that names the writer.

Branch `dormant-flush-039`, from `origin/release-0.39.0` (`9157672e`). Local:
QEMU x86-64 guest, 12 vCPU shared with other agents, Linux 7.0.0, Crystal
1.21.0. Every heavy run held `heavy.lock` once and was bounded by
`bench/run_bounded.sh`.

## The faulting configuration

From `bench/dormant_flush_race.cr` and the campaign runner at `2a46123`
(`bench/log/linux/2026-09-27-dormant-revive-race/run-dormant.py`, eleven
lanes, five at a time; the `dormant_flush` lane runs the harness parent with
`GCRY_SEGV_REPORT=1`):

- **Harness:** the queued (default) arm's children, `--child`, with
  `GCRY_MOSTLY_EMPTY=1` (ignored on headerless, it says so at start-up),
  `GCRY_UNMAP_GUARD=1`, `GCRY_SEGV_REPORT=1` and `GCRY_STW_WATCHDOG_MS=5000`.
  Four workers allocate a 40 960-byte atomic block, write and verify it every
  64 bytes, then `GC.free` it, 10 000 times each. One collector thread runs
  `GC.collect` and sleeps 1 ms. There are 40 000 ballast objects.
- **Build:** the default layout, headerless with the bitmap allocator; no
  TLAB, nursery or incremental marking.
- **Sweep:** after the world restarts (`sweep_after_world?`: lazy on, no
  TLAB, `madvise_free_pages` off, multi-mutator and no
  `parallel_empty_chunk_munmap`), inside `during_live_chunk_walk`. Nothing
  in the lane sets `GCRY_DISABLE_LAZY_SWEEP`, `GCRY_PAGE_DONTNEED`,
  `GCRY_INCREMENTAL` or `GCRY_TLAB`.
- **Large cache:** retain 0 (Linux default). Every `GC.free` cached the
  chunk and then trimmed to 0. The trim decides, under `@alloc_lock`, to
  release directly or to queue for the collector when `@live_chunk_walk` is
  set (`heap.cr:2417-2434` at 2a46123).
- **Dormant budget:** release-on-collect (a7debe4) makes multi-mutator
  size-class empties dormant after `GC.collect`. It never applies to large
  chunks: the sweep's dormant path is `!ChunkHeader.large?`.

## What the report says, read against the layout

```
gcry: SIGSEGV at 0x7f96fa236024 — in a chunk gcry RELEASED — base 0x7f96fa236000,
45056 bytes, large-object release, at collection 120; the write is 36 bytes into it.
Collections since: 0. First user word at release: 0x90000a000 (type_id 40960).
Blocks still allocated at release: 1
```

At 2a46123 a large chunk was a 32-byte `ChunkHeader`, then the 16-byte large
block header (`size` u32 at +32, `flags` u32 at +36, `next_free` at +40),
then the object at +48. 45 056 is `align_up(48 + 40 960, 4096)`.

- **"First user word" was the block header, not user data.**
  `guard_user_tag` read `base + ChunkHeader::SIZE + BlockHeader::SIZE`, and
  `BlockHeader::SIZE` is 0 on headerless, so it read +32. (The 2026-10-14
  back-link change, 49788b15, moved it to `large_data_offset`.) Read as a
  header, 0x0000_0009_0000_a000 is `size` 40 960 and `flags` 0x9, which is
  `FREE | LARGE`. That is exactly the header `cache_large_chunk` writes. A
  live block in this harness carries `ATOMIC` (0x2), which
  `malloc_atomic` → `alloc_large(rounded, ATOMIC)` → `set_used_large` sets
  and the cache's rewrite drops. **The chunk was in the large cache when it
  was released.**
- **"Blocks still allocated: 1" was not a reading.** For a large chunk,
  `guard_occupied` returned `BlockHeader.free?(header) ? 0 : 1`, and
  `BlockHeader.free?` is constant `false` on headerless. Every large release
  on the default layout recorded 1. The unsafe control arm below releases
  only cached FREE chunks and prints the same "1". The code was still this way
  on `9157672e` (`collect.cr:1482`).
- **The access was to the block header's `flags` word (+36), not to the
  worker's buffer**, which starts at +48.

So the item's description ("a worker wrote into its own buffer after the
chunk was released, and the release saw the header USED") is wrong in both
halves.

## Not the 0.38.0 dormancy bug

Three independent reasons:

1. That bug needs the sweep inside the stop. This lane sweeps after it, and
   the 0.38 FINDINGS say so themselves: "The default after-world sweep never
   had it."
2. Dormancy applies only to size-class chunks taken by a pool cursor. The
   released chunk was large: guard kind `LARGE`, 45 056 bytes, a large block
   header.
3. Its symptom is pages `MADV_DONTNEED`ed under live objects that stay
   mapped and read zero. This was an access to a range the unmap guard had
   made `PROT_NONE`.

## The signature, reproduced on the same binary

The harness's unsafe control, `GCRY_TRIM_IMMEDIATE=1`, makes mutators release
outside the live-walk protocol. Three `--child` runs of the 2a46123 binary all
faulted (`old-immediate-reports.txt`). The writer pc is resolved with
`addr2line` on that binary:

| child | report | writer |
|---|---|---|
| 2, 3 | 45 056 bytes, large-object release, **36 bytes into it, 0 since, first word 0x90000a000, 1 allocated** — the sighting's line apart from addresses and collection number | `free_large?` (`block.cr:358`) ← `sweep_large_one` (`collect_sweep.cr:428`), entered after `with_alloc_lock` at `collect_sweep.cr:97` |
| 1 | same, 0 bytes into it | `sweep` (`collect_sweep.cr:70`, `chunk.value.next`) |

So the report line is what a **lazy-sweep walker** prints when it meets a
cached large chunk that a mutator released while the walker waited for
`@alloc_lock`. The walker reads the chunk's `next` and `size_class` without
the lock, then the block header's `flags` first thing under it.

### Why the default arm should not reach it, and what else reads +36

At 2a46123 the lazy sweep runs inside `during_live_chunk_walk`, which sets
`@live_chunk_walk` under `@alloc_lock`. A mutator's trim checks the flag under
the same lock before releasing, and queues for the collector if it is set.
The collector itself releases only after the walks
(`flush_pending_large_release`, `trim_large_cache(defer: false)`). Read for
this item, with no gap found:

- every `guard_release(…, GUARD_KIND_LARGE)` / `munmap` site
  (`release_large_chain`, the `trim_unlocked` control, the post-detach loop
  reached only with `defer: false` or `trim_immediate`);
- every `sweep(after_world: true)` call: one, wrapped;
- every writer of `@live_chunk_walk`: `during_live_chunk_walk` only, never
  nested;
- the incremental slice's flush path (`collect_a_little`): unreachable,
  incremental off.

The only other code that reads a large header's `flags` before touching the
chunk header is the owner's `GC.free`. `free_owned?` → `with_alloc_lock` →
`cache_large_chunk`'s double-insert check runs after a lock wait. For that to
fault, the sweep must first have cached the owner's live block, which is a
lost root, and then trimmed it. In every child below, the sweep cached no
large block at all: `lg_by_sweep` was 0 in all 808 children. The re-entry
alternatives were also checked: the collector cannot sweep and release at
once, worker-triggered collections coalesce on the post-stop mutex, and the
STW watchdog touches no chunk. None of them opens a path.

[INFERENCE] One run is all there is. Seed 20012 had 2 of 6 queued children
fail, and its first failing child's first `gcry:` line is the report. Seed
20013's only quoted line is the start-up note about `GCRY_MOSTLY_EMPTY`. The
parent quoted the first `gcry:` line, and every child prints that note first,
so what 20013's child died of was never recorded. In the same run both
scheduled children failed: one with empty output, the other having printed
only that note. Those are 30-second programs that print one line. A child
whose writes fail (BoundedChild keeps child output in a `/tmp` tempfile, and
`/tmp` on this host is a small tmpfs) would fail exactly that way, and so
would a queued child that ends with a `puts`. In 20012's reporting child the
start-up note is also missing before the report, which fits writes failing
at start-up. Not measured: the host state of 2026-09-28 is gone.

## Coverage: the gate had stopped making the traffic

Since 568cd1d9 (2026-10-03, "trim once the cache is 2 MiB past the
retain"), `GC.free` of a large block no longer trims on every free. Four
workers cycling one 40 KiB block each never put 2 MiB in the cache. On
`9157672e` a child made **0 mutator trims**, `live_walk_direct` and
`live_walk_queued` both 0, also with 48 workers (`DORMANT_FLUSH_RACE_WORKERS=48`).
The stress arms then had no mutator unmaps to race:

| harness | queued arm | stress control (`TRIM_IMMEDIATE`) |
|---|---|---|
| 9157672e as shipped, 3 gate runs | 0 of 18 | **0 of 18**, "stress missed the unsafe window" |
| with per-free trim (3d097aeb), 11 gate runs | 0 of 66 | **66 of 66** |

`gate-runs.txt`. Only the deterministic scheduled control was still testing
anything. The 400 runs of campaign-048 used `c85a35c`, which does not contain
568cd1d9, so they did exercise the path. [INFERENCE] Lanes on later trees
(campaigns 049-051 used `955827a`, which does) did not, so their silence says
nothing about this fault.

## Reruns, with `GCRY_TRACE_LARGE=1`

`repro.py`: each batch holds the lock once and starts 4 children of each arm
at once (48-56 threads on 12 vCPU, other agents' load on top). The children
run with the queued arm's environment plus `GCRY_TRACE_LARGE=1`, each under
`run_bounded.sh 300`. It expects `bin/df_<arm>` and the worktree as `wt/`
beside it, as it was run here. Two sessions: `old,new` for 21 batches, then
`old,trim` for 80. Results are in `repro-results.tsv`.

| arm | binary | children | failed | mean s | mutator trims (direct / queued) | lazy+flush walks |
|---|---|---:|---:|---:|---:|---:|
| old | 2a46123 | 404 | **0** | 7.5 | 12 744 909 / 1 374 295 | 190 880 |
| new | 9157672e harness | 84 | **0** | 1.0 | 0 / 0 | 3 422 |
| trim | 3d097aeb | 320 | **0** | 5.7 | 11 963 169 / 835 590 | 81 828 |

About 21 minutes of lock time. No child refused a free, and in every child
`lg_twice`, `lg_taken_used` and `lg_by_sweep` were all 0.

## Changes

- **`guard_occupied` reads `BlockHeader.free_large?`** (f0fdf4e3), so
  "Blocks still allocated at release" for a large chunk is its real FREE
  flag on both layouts. Regression in `spec/research_tables_spec.cr`: a
  freed-and-trimmed large chunk must record 0 (red before the fix, "got: 1"),
  and a release recorded with the block live must record 1 (control). Green
  on headerless and `-Dgcry_block_headers`. The trim-harness control's
  report now reads `First user word at release: 0x5c (type_id 92). Blocks
  still allocated at release: 0`. 0x5c is the worker's fill byte, at +64 in
  today's layout, and the access is +52, today's large `flags` word.
- **`make dormant-flush-race`** (3d097aeb):
  - Workers call `trim_large_cache` after each free, which restores the
    mutator unmaps the gate exists for (table above).
  - The parent prints the first failing queued child's whole report:
    every `gcry:` line except `GCRY_TRACE_LARGE`'s, plus the trace lines
    naming the released base. That includes the `gcry: writer —` pc and
    return addresses that were printed in 2026-09-28 and discarded.
  - The start-up note is no longer quoted as a child's failure.

## Open

- No path in the default arm explains the sighting. If it recurs, the
  writer pc in the gate's output, resolved with `addr2line` on that
  campaign's binary, separates the two candidates: `sweep_large_one` means a
  release ignored `@live_chunk_walk`, and `cache_large_chunk` from `GC.free`
  means the sweep cached a live block.
- Seen in passing, not chased: `recalc_free_bytes` (`collect_sweep.cr:2102`
  on 9157672e) also asks `BlockHeader.free?` of a large header. On headerless
  it would leave cached large bytes out of a recount.
