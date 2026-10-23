# The chunk-list-drift stall is the fast arm's cycle, not a gcry regression (2026-10-23)

**Host:** Linux 7.0.0-38-generic x86_64 (QEMU, 12 vCPU), Crystal 1.21.0.
**Trees:** `release-0.39.0` at `f90a1793` (round 3, `b888ac96` + docs), and
`6fc6665c`, the tree before round 3, for the comparison. Every run bounded by
`bench/run_bounded.sh` under the host lock.

## The stall

The 0.39.0 overnight stress on `b888ac96` (`../2026-10-22-0.39-stress/`, round
3) killed `make chunk-list-drift` at 600 s in 1 of 6 runs
(`overnight-stall-capture.log`). The stalled process was the gate's
`--child --fast` child: the main thread and one born thread running (`R`,
no wait channel), SYSMON asleep, the three markers and the idle thread in
futex waits. gdb could not attach: the child had not consented to ptrace,
and the host runs `ptrace_scope=1`. The same gate had 0 stalls in 6 runs on
each of the four trees before.

## Reproduced, with stacks

The child now declares itself traceable (`PR_SET_PTRACER_ANY`, as
`stw_mt_property_test` and `thread_churn_uaf` do), and the fast child was run
four at a time under the lock (`loop.sh`). It stalls readily under that load:

| tree | fast children | hung (150 s) | crashed | finished |
|---|---:|---:|---:|---:|
| 0.39.0 round 3 (`f90a1793`) | 12 | **7** | 5 | 0 |
| before round 3 (`6fc6665c`) | 12 | **5** | 6 | 1 |

(`repro-runs.txt`; the 0.39.0 row is `fast-base`, `fast-f90a` and the four
children of `natural-cycle-gdb.txt`.) The crashes are the fast arm's known
use-after-free, at `flush_pending_dormant_chunks` or `bitmap_pool_candidate?`.
The rates do not differ between the trees, so this is **not a round-3
regression**: 1 stall in 6 runs on the night against 0 in 24 before is
within chance (p ≈ 0.2).

Every hang has the same stacks (`natural-stall-0.39-round3.log`,
`natural-stall-pre-round3-6fc6665c.log`):

```
Thread 1 "drift-f90a" (the collector, in GC.collect)
#0  __GI_madvise
#1  release_physical_pages        platform/linux_softdirty.cr:133
#2  release_reusable_pages        platform/linux_softdirty.cr:147
#3  flush_pending_dormant_chunks  collect_sweep.cr:1115
#4  run_collection_body           collect.cr:3234
Thread 2 "drift-f90a" (a born thread, allocating its main Fiber)
#0  bitmap_pool_candidate?        bitmap_alloc.cr:1420
#1  bitmap_take_pool_chunk        bitmap_alloc.cr:1313
#2  bitmap_refill_pool            bitmap_alloc.cr:1249
```

plus the idle thread waiting its post-stop turn (`wait_post_stw_turn`). Both
running threads are walking `@chunks`, and both walks are bounded only by
reaching null. Each of the 12 hung children's logs carries the
`gcry: refusing to release chunk ... Kept mapped` line (printed once per
process), and none of the 11 crashed children's does.

## The mechanism: the list closes into a cycle

`cycle.gdb` reads `Gcry::default_heap`'s `@chunks` (offset 6576 in this
build, from `offsetof`) and runs Floyd's walk over `ChunkHeader#next`
(offset 0). On three natural hangs (`natural-cycle-gdb.txt`):

    CYCLE: 11 chunks from the head, then a loop of 40 chunks
    CYCLE: 0 chunks from the head, then a loop of 31 chunks
    CYCLE: 0 chunks from the head, then a loop of 27 chunks

So `@chunks` is a loop, and in two of the three the loop is entered at the
head itself.

How: the fast arm is `sweep_mutator_latch = false`, half of the pre-fix
shape. Its sweep re-reads the mutator count per decision, so in some
collections it drops an empty chunk for release (pointing its `next` into the
unmap queue) while still leaving it on `@chunks`: the live list runs on into
the queue. That is the documented pre-fix defect, and it is why the arm
strands chunks and crashes. Then `flush_pending_empty_chunks_locked` refuses
a queued chunk, because a mutator took a block from it after the sweep or
holds it as a cursor (`refuse_occupied_release`). That refusal was added on
2026-09-14, after the latch fix. It links the chunk back in front of
`@chunks` (`ChunkHeader.link(keep, @chunks)`), assuming it is not on the
list. On the fast arm's list it already is, through the queue, so the list
becomes `keep → old head → … → dropped chunk → queue → keep`. The dormant
flush runs next (`during_live_chunk_walk`), and it walks the loop
forever. Any mutator that refills a bitmap pool walks it too.

On the shipped tree the latch makes the sweep's relink and drop decisions
agree, so a queued chunk is never still on the list, and a refused chunk
linked in front is one more chunk on it.

### Forced: every release refused

`GCRY_REFUSE_EMPTY_RELEASE=1000000000` refuses every empty-chunk release, so
every queued chunk is linked back (`repro-runs.txt`, `refuse` and
`refuse240`):

| child | rounds | outcome |
|---|---:|---|
| fast + refusals | 1200 | 4 of 4 hung (+2 of 2 in `forced-cycle-gdb.txt`, both a cycle) |
| fast + refusals, four at once | 240 | 8 of 8 hung, the latest between rounds 160 and 200 |
| fast + refusals, alone and serially | 240 | **118 of 150 hung, 32 exited cleanly** in 1.0-3.7 s, 0 crashed (`pertry-r240.txt`, `pertry.sh`) |
| shipped + refusals | 1200 | 4 of 4 exited cleanly (15-17 s) |
| shipped + refusals | 240 | 8 of 8 exited cleanly (2-3 s) |

The shipped tree keeps an acyclic list under the same refusals. The fast
arm's hang is likely but not certain: the refusals make every dropped-but-
listed chunk close the cycle, but the drop itself still needs the latch-off
race, a thread born between the sweep's drop and relink decisions for the
same chunk. Run alone, as the gate runs it, a 240-round child escapes 21% of
the time (32 of 150; 33% at the 99.9% upper bound).

## What was wrong: the gate waited on a child with no deadline

The fast arm is broken on purpose, and a hang is one of its outcomes, as a
crash is. The harness ran every child with `Process.run` and no deadline, so
one hung fast child hung the gate. `bench/bounded_child.cr` exists for this
("undefined behaviour is not obliged to crash"), and 23 other harnesses,
`thread_churn_uaf` and `large_cache_race` among them, already use it.
`chunk_list_drift` did not.

There is nothing to fix in `src/`. The cycle needs the latch off, and the
latch-off arm exists to rebuild the pre-fix race.

## The fix (`bench/chunk_list_drift.cr`)

* **Every child runs under `BoundedChild`.** The deadline is
  `max(120 s, rounds / 10)`, or `BENCH_CHILD_TIMEOUT_S`. A fast child that
  hangs counts as a crash: its buckets are kept, and with none it is run
  again (`FAST_ATTEMPTS`). The parent prints how many hung. A hang in any
  shipped child (shipped, startup regime, window, window-free, the refusal
  arm's shipped child) fails the gate and prints that child's thread capture.
* **The children consent to ptrace** (`PR_SET_PTRACER_ANY`), so
  `stall_capture.sh` gets their stacks under `ptrace_scope=1`.
* **A refused-releases arm** drives the hang on every run, and makes it a
  regression with a control. With `GCRY_REFUSE_EMPTY_RELEASE` for 240
  rounds:
  * the shipped child must exit cleanly, having refused at least 1 000
    releases (it refuses about 6 000 to 18 800, because a kept empty chunk is
    queued and refused again at each major);
  * the fast child must hang, and is killed at 20 s. It gets up to **ten**
    tries (`REFUSE_FAST_ATTEMPTS`). Over all 230 tries measured (150 alone,
    80 inside the 55 gate runs below), 57 escaped: 0.25, and 0.35 at the
    99.9% upper bound. The tries are separate processes, so all ten escape
    with probability 0.35^10 = 2.4e-5 per gate run at that bound, and
    9e-7 at the measured rate. An escaped try costs 1-4 s.

  If the fast child stops hanging, the construction no longer reaches the
  cycle and the shipped child's clean exit means nothing; that fails the
  gate, like the window control. If the parent were not bounded, this arm
  would hang the gate on every run.

  The first version gave it three tries, and that was red once in 50 gate
  runs (`gates-3tries-summary.txt`, run 48, `gate-48-three-escapes.log`:
  three clean exits with 13 366, 9 836 and 17 005 refusals). That matches
  0.21^3 = 1% a run. Making the hang certain instead would take a research
  hook in `src/` between the sweep's per-chunk drop and relink decisions, to
  flip the latch-off mutator count there on demand. That would put a hook
  into the sweep's chunk loop for a gate whose subject is a harness deadline,
  so the try count is set from the measured rate instead.
  The rate is this host's (12 vCPU). CI's 4-vCPU runners are unmeasured.

## Red → green

| run | harness | outcome |
|---|---|---|
| `red-old-harness-forced.log` | `origin/release-0.39.0`, `GCRY_REFUSE_EMPTY_RELEASE` exported to every child | **STALLED** at 300 s, on `--child --fast` (exit 2) |
| `green-gate.log` | this branch, plain `CHUNK_DRIFT_ROUNDS=1200` | ok in 49 s; refusal arm: shipped 6 063 refused and clean, fast hung and killed at 20 s |
| `green-every-child-refusing.log` | this branch, refusals exported to every child, `BENCH_CHILD_TIMEOUT_S=30` | returns in 138 s: all three fast children hung and were killed, and the verdict names it (exit 1, as it must with the arm broken) |

## After: the gate, bounded

`gates.sh` runs the whole gate (`CHUNK_DRIFT_ROUNDS=1200`) one run per lock
hold, each bounded at 600 s.

| harness | gate runs | passed | stalled | red |
|---|---:|---:|---:|---:|
| before (overnight, `b888ac96`) | 6 | 5 | **1** | 0 |
| three refusal tries (`gates-3tries-summary.txt`) | 50 | 49 | 0 | 1, run 48: three escapes |
| ten refusal tries (`gates-after-summary.txt`) | **55** | **55** | **0** | **0** |

In the final 55 runs, which took 32-160 s each:

* **Fast children:** two runs (10 and 29) had one hang on its own. Under the
  old harness each would have been a 600 s stall; here it was killed at
  120 s and run again.
* **Refusal arm, fast child:** it needed 1 try in 39 runs, 2 in 10, 3 in 3
  and 4 in 3, so 80 tries in all and 25 escapes.
* **Refusal arm, shipped child:** it refused 8 837 to 18 801 releases and
  exited cleanly every time.

Also, on the three-try harness, Main ran every hand-off check once, all
exit 0: format, lint, all_specs default and headers, process_spec default,
headers and headers+freelist, `make alloc-entry-frame counter-loss
heap-counters mark-audit`, `make windows-typecheck`, `make darwin-typecheck`,
and `make chunk-list-drift` ×10.

## Not changed

* `src/`: no gcry defect. The refusal's relink assumes a chunk the sweep
  queued is off the list, and on the shipped tree it is.
* The fast arm's semantics. Making it release occupied chunks
  (`release_occupied_anyway`) would turn the hang back into the pre-2026-09-14
  use-after-free, which is a crash and not a cheaper outcome. The arm keeps
  the shipped refusal and is bounded instead.
