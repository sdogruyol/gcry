# The cached-large-chunk sighting: the walk re-read, and a rate bound (2026-11-01)

The ROADMAP item "A cached large chunk released while something still read
its block header" (`dormant_flush`, 2026-09-28; narrowed in
`../2026-10-21-dormant-flush-sighting/FINDINGS.md`). This pass re-read the
release paths against every reader of a large chunk's header on the 0.39.0
tree (`c0d570c5`), found no interleaving to force with a hook, and ran the
restored-trim gate's queued children 3 600 times on GitHub's Linux runners:
0 failures. The item stays open, narrowed by that bound.

## The protocol, re-read on 0.39.0

The sighting's reader (same binary's unsafe control) was the after-world
sweep: it reads a chunk's `next` and flags with no lock, then waits for
`@alloc_lock` and reads the large block header's `flags` in `free_large?`
(`collect_sweep.cr`, `sweep_large_one`). The default arm's guard is
`@live_chunk_walk`. What was checked:

- **Mutator releases.** A trim (`Heap#trim_large_cache`) detaches under one
  hold of `@alloc_lock` (`detach_large_cache`: off the buckets, the list and
  the index, `unlink_detached_large`) and decides under a second hold:
  `@live_chunk_walk` set → `queue_large_release`, else
  `release_large_chain`. A walker can reach a detached chunk only through a
  pointer it read before the detach, i.e. while its walk is in flight, and
  the flag is raised under the lock before the walk reads the head and
  lowered under it after the walk's last access (`during_live_chunk_walk`'s
  `ensure`), so the second hold sees it and queues. A walk that started
  between the two holds reads a list the chunk has already left.
  `recycle_large_mapping`, the other mutator unmapper, refuses while
  `@live_chunk_walk`, `@collecting` or `@world_stopped` is set.
  `GC.free` and `alloc_large` read cached headers only under `@alloc_lock`
  (`cache_large_chunk`, `take_large_free`); `free_result` reads the header
  before the lock only for the caller's own block, which no one else can
  cache.
- **The after-world walkers.** One `sweep(after_world: true)` call, wrapped;
  the three `flush_pending_*` walks, wrapped. `@relink_walk` (a relinking
  sweep) makes a trim decline before it detaches anything.
- **Collector releases.** `flush_pending_large_release` (twice, both outside
  the wrapped walks), `release_moved_large` (under the lock, after the
  walks), the collector's `trim_large_cache(defer: false)` (after the walks;
  the detached chunks are on no list, bucket or index), and the incremental
  finishing path's flush (incremental off in this lane).
- **Readers without the lock.** The mark (in the stop; a chunk detached is
  out of the index the mark looks up, and a frozen detach releases nothing
  before the stop ends), `free_result`'s pre-lock `block_allocated?` (own
  block only), `Invariant.after_free`/`Trace.after_free` (off by default).

No path lets a chunk be released while a reader still holds it. So no hook
was written: there was no interleaving to force. [INFERENCE] The 2026-09-28
failure stays unattributed: `2a46123` predates the October changes to these
paths (batched detach, back-links, the restored trims), and the one quoted
line cannot name its writer.

## Stress, Linux x86_64 and arm64

`probe-large-cache-flush.yml` (copied here), push-triggered on
`probe/large-cache-flush` (deleted after), checkout pinned to `c0d570c5`
(0.39.0's tree, which has the restored per-free trims of 3d097aeb). Each job
builds `bench/dormant_flush_race.cr` (`-Dgc_none`, debug, default headerless
bitmap layout, as `make dormant-flush-race`) and runs its `--child` with the
queued (default) arm's environment (`GCRY_MOSTLY_EMPTY=1
GCRY_UNMAP_GUARD=1 GCRY_SEGV_REPORT=1 GCRY_STW_WATCHDOG_MS=5000`), two at a
time, each under `timeout 300`. The sighting's lane configuration: lazy
sweep after the world, four workers, the per-free trims.

| run | runner | children | failed | timed out |
|---|---|---:|---:|---:|
| [41202609665](https://github.com/sdogruyol/gcry/actions/runs/41202609665) (`9e52f22b`) | ubuntu-latest | 1 200 | 0 | 0 |
| | ubuntu-24.04-arm | 1 200 | 0 | 0 |
| [41205878106](https://github.com/sdogruyol/gcry/actions/runs/41205878106) (`bcc0c2d0`) | ubuntu-latest | 600 | 0 | 0 |
| | ubuntu-24.04-arm | 600 | 0 | 0 |
| **total** | | **3 600** | **0** | **0** |

The second run also kept each child's traffic line (sum over its 1 200
children): 671 160 live walks, 43 873 882 mutator releases made directly
(no walk in flight) and 4 322 969 queued behind a walk, and `lg_by_sweep` 0
in every child (the sweep never cached a live block, so the owner's
`GC.free` candidate never arose). Per child, about 560 walks, 36 600 direct
and 3 600 queued releases: the race the gate is for was being run, on both
architectures.

With the 724 local children of `../2026-10-21-dormant-flush-sighting/`, 0
of 4 324 since the sighting. By the rule of three the per-child failure
rate on the runners is below 3 / 3 600 ≈ 0.083% (95%), and below 0.17% on
each architecture alone; the sighting's run failed 2 of 6.

## Open

The gate prints the first failing queued child's whole report, writer pc
included. If it recurs, `addr2line` on that binary names the reader:
`sweep_large_one` (a release that ignored `@live_chunk_walk`) or
`cache_large_chunk` from `GC.free` (the sweep cached a live block).

Seen in passing, not this item: the incremental finishing slice's flush
(`collect.cr`, `collect_a_little`) neither takes nor resets the large-cache
counters. [INFERENCE] Under `GCRY_INCREMENTAL=1`, `@large_alloc_since_major`
and the budget then carry over its majors until a collection on the normal
path. Opt-in path; RSS only.
