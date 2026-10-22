# macOS: the live object lost on `d1549e2f` was the late clear of `@world_stopped` (2026-10-22)

ROADMAP item "macOS: one live object lost on `d1549e2f` in the 2026-10-21
probe — unattributed" (`bench/log/macos/2026-10-21-tlab-nursery-hang/`,
`probe/macos-latest-pre-1/tlab-only-s1-6.log`): `root 11 DEAD … block={found:
true, free: true, size: 64, flags: 1, first_word: 0xC0FFEE42C0FFEE01}`, 1 in
4 000 runs of that build.

**Verdict: the late clear of `@world_stopped` (fixed by `0d1e2b6a`,
2026-10-01,
`bench/log/macos/2026-10-01-darwin-index-late-clear/`), not the pthread
list lock fix.** The evidence so far:

1. The loss reproduces on `d1549e2f` at a usable rate: 3 in 569 runs of an
   eight-worker shape on macos-latest, same signature as the sighting
   (round 1 below).
2. Restoring the late clear on **release-0.39.0**
   (`GCRY_STW_LATE_CLEAR=1`, the gate's red-arm knob) reproduces the same
   signature on Linux at 2 in 82 runs of the CI step's tlab-only shape, and
   the same flush-phase stalls `d1549e2f` shows. Without the knob,
   release-0.39.0 shows none (Linux below; macOS: round 2, pending).
3. The mechanism, read from the code at `d1549e2f` and at release-0.39.0
   (`revive_dormant_chunk`, `tlab_refill_locked` and `allocate` are the same
   in both): a thread resumed while `@world_stopped` still read true takes
   the stopped-world allocation path. It pops the class freelist under the
   class lock (`tlab_bypass` → `alloc_old_small`), while a peer that already
   saw the flag clear refills its TLAB from **the same list under
   `@alloc_lock`**. Two lock domains then write one list. With the flag cleared
   before the resume, only the collector, alone in the stop, can take the
   first path.

The macOS cherry-pick arms (`pth`, `lc`) and `rel` are running in round 2
(run 39762990317). Their numbers were not in when this was written, and
the ROADMAP item stays open until they are.

## The signature says "a carve or relink rewrote a live block"

`flags: 1` is `FREE` and nothing else: no `ATOMIC` (the harness allocates
with `malloc_atomic`), no `SWEPT` (128, which the sweep's freelist link sets),
and mark generation 0. So the sweep did not free this block. One of the
writers that store a whole new header did it: a chunk carve
(`refill_size_class`, `revive_dormant_chunk`), a freelist relink
(`splice_free_nodes`, `scrub_one_freelist`, `link_revived_tail`,
`fold_prefer_into_global`), or `tlab_free_small`. The payload still holds
the cookie (`first_word` is `MAGIC`). All four macOS losses (the 2026-10-21
one and the three below) are at an address ending `…7fa0`/`…bfa0`, which is
the highest block of its 16 KiB-aligned run. A carve links blocks from the top
down, so that block is the first one popped from a carved chain.
[INFERENCE] Each loss is a block that was handed out from a chain while
another thread was still carving or relinking the same chain.

## Round 1: raising the rate on `d1549e2f` (macos-latest)

Run [39734461333](https://github.com/sdogruyol/gcry/actions/runs/39734461333),
probe commit `b1cc661c` on `probe/mac-lost-object`. There were five jobs
(119676800600, 119676800858, 119676800872, 119676800983, 119676801088),
each 150 min long, all on `d1549e2f`. Each ran six shapes of the tlab-only
arm round-robin (`variants-r1.txt`, `probe_loop_r1.sh`) under the CI step's
environment, and `bench/run_bounded.sh` bounded every run.

| shape | runs | lost | gcry stall (exit 2) | #17486 (exit 3) |
|---|---:|---:|---:|---:|
| `seed6`: the sighting, `--seed=6 --workers=2,4 --iterations=200` | 573 | 0 | 1 | 0 |
| `base`: CI step's tlab-only, seeds 1..10 | 571 | 0 | 0 | 1 |
| `long4`: `--workers=4 --iterations=1000` | 571 | 0 | 0 | 0 |
| `long4x3`: three `long4` at once | 1 713 | 0 | 0 | 0 |
| **`long8`: `--workers=8 --iterations=1000`** | **569** | **3** | **9** | 0 |
| `births`: ten 4-worker contexts per process | 568 | 0 | 1 | 0 |

The three losses are `round1/pre-{2,3,4}-long8-*-lost.log`:
`after collect #453 / #664 / #175: root N DEAD … size: 64, flags: 1,
first_word: 13907096144816631297`. That is the sighting's signature
exactly. The exact seed is irrelevant: 0 in 573 repeats of seed 6.

Ten of the eleven gcry stalls print `STOP-THE-WORLD STALLED … phase=flush`.
The collector sits in `scrub_freelists` → `scrub_one_freelist`, walking a
class freelist that never ends (`round1/pre-1-long8-r84-flush-stall.log`).
That is a freelist cycle, the outcome `allocate`'s comment predicts for a TLAB
refilled in a stopped world. The eleventh (`round1/pre-1-long8-r15-gate-stall.log`)
is a different deadlock. Main is in `Thread.new` inside
`Parallel#wake_scheduler`'s mutex, in an allocation whose TLAB refill fell
through to `collect`, and it spins in `MonitorGate.close`. SYSMON waits for
that same mutex in `increase_parallelism`. The refill falls through to
`collect` only when `tlab_refill_once` sees the world stopped. [INFERENCE]
The late clear is how that happens here.

The 2026-10-21 probe ran only `seed6`/`base`-like shapes: 1 in about 500
tlab-only runs there, against 0 in 1 144 here, which is within chance.

## The same loss on Linux with the late clear restored on release-0.39.0

Local x86-64 (shared QEMU guest), release-0.39.0 `32ce703a`,
`-Dgc_none -Dgcry_block_headers`. The harness is `harness.cr`: the shipped
`bench/stw_mt_property_test.cr` plus `--worker-collect=N`, a per-phase
`heap_collections=` line, and `heap_collections_since_verify=` on each error.
The CI step's environment, `--tlab --iterations=200 --workers=2,4`, seeds
1..N, each run under `bench/run_bounded.sh`.

| arm | runs | lost (DEAD, `flags: 1`) | flush-phase stall | TLAB-refill OOM | extra collections per 4-worker phase |
|---|---:|---:|---:|---:|---:|
| `GCRY_STW_LATE_CLEAR=1` | 82 | **2** (runs 15, 72) | 6 | 2 (runs 14, 55) | ~230 (≈ 430–475 against the harness's 201) |
| same, debug build (below) | 54 | **1** (run 53) | 1 | 0 | same |
| shipped (no knob), `--worker-collect=8`, 300 iterations | 60 | 0 | 0 | 0 | ~370 (by design) |
| shipped, no knob, plain | 1 run | 0 | 0 | 0 | **0** (201 = 201) |

(`linux/*-progress.txt`; logs `linux/rel-late-clear-r15.log`, `-r72.log`,
`-r14.log`, `-r83-flush-stall.log`.)

- The Linux losses carry the macOS signature (`free: true, flags: 1`, cookie
  intact; size 80 is the x86-64 header layout's class for the same request).
- **The late clear makes the workers collect.** A worker resumed inside
  `tlab_alloc_small` finds its TLAB flushed. `tlab_refill_once` then does
  `break if @world_stopped`, and `tlab_refill` falls through to
  `collect(scan_stack: true)`, because the cycle in flight is not its own.
  Shipped release-0.39.0 runs exactly the harness's collections. With the
  knob it runs twice as many, started on Parallel workers.
- **Workers collecting is not the cause.** With 22 000 collections started
  on workers by `--worker-collect=8` and no late clear, there were 0 losses.
  The cause is the window itself, the time after the resume and before the
  clear.
- The two OOMs, `failed to refill TLAB size class 48/80` from `tlab.cr`,
  come from the same window. A refill sees the flag, then the bypass check
  after it does not, and `oom!` runs. [INFERENCE] The other open macOS item,
  "a TLAB refill out of memory at a new thread's start (`b9394a01`,
  2026-09-28)", is this on a build that also predates `0d1e2b6a`. It is not
  attributed here.

### Which race in the window

A debug copy of release-0.39.0 counted one candidate: `install_revived_chunk`
finding its chunk already revived, which means two threads revived one dormant
chunk. `revive_dormant_chunk` carves outside `@alloc_lock` on the class-lock
path and inside it on the TLAB path. It printed once in 54 runs, in the run
that stalled in `phase=flush` (`linux/dbg-r42-double-revive-stall.log`), and
**not** in the run that lost an object (run 53; that loss had
`heap_collections_since_verify=1`). So a double revival is one way the window
corrupts a class list. [INFERENCE] It is not the only one. `tlab_refill_locked`
moves `@freelists[class]` under `@alloc_lock` alone, and the bypass pop moves
it under the class lock alone. A block popped by one path while the other
relinks the chain through it ends up handed out and also linked, and the next
relink rewrites its header to plain `FREE`. Which writer hit run 53's block
was not isolated.

Neither race is reachable on release-0.39.0 as shipped. With TLAB on, the
bypass path runs only while `@world_stopped` is true, and since `0d1e2b6a`
(Darwin/Windows) and 2026-08-22 (Linux) that is only inside the stop. There
the collector is the one running thread: Linux's signal-exempt SYSMON waits
at `allocate` (`wait_if_world_stopped_other_thread`), and Darwin suspends
every listed thread. With TLAB off, the default, every revival and pop of a
class takes that class's lock.

## Was it the pthread list lock (`9c19480b` … `131f6267`)?

[INFERENCE] No. That defect hangs in libpthread, or leaves a thread born
during the stop unscanned. The loss here is a header rewrite, with the
collector's mark not involved (`SWEPT` clear), and the Linux reproduction
has no Darwin stop code at all. The round 2 `pth` arm is the measurement.

## Round 2 (running when this was written)

Run [39762990317](https://github.com/sdogruyol/gcry/actions/runs/39762990317),
probe commit `8dd6af5f`. Five macos-latest jobs, 290 min each. Each job
builds six arms and interleaves them, `long8` only (`variants-r2.txt`,
`probe_loop.sh`, `probe-ci.yml`):
`pre` (`d1549e2f`), `pth` (+ `arms/pth.patch` = `9c19480b 8bc3b355 e69e36fe
131f6267`), `lc` (+ `arms/lc.patch` = `0d1e2b6a`), `rel` (`32ce703a`), `rlc`
(`rel` + `GCRY_STW_LATE_CLEAR=1`), `relwc` (`rel` + `--worker-collect=16`).
At round 1's rate, `pre` should show about 5 losses and 15 flush stalls.
Expected outcome if the verdict holds: `pre`, `pth` and `rlc` lose objects
and stall in `phase=flush`, while `lc`, `rel` and `relwc` do neither, and
only the first three show extra `heap_collections`. `arms/fp.patch`
(`6462255f`, FP/SIMD register capture) applies and builds but is not in round
2: the Linux reproduction captures FP state in the signal frame, so it
cannot be that.

## Files

- `probe-ci.yml` (round 2's workflow; round 1's is in the probe branch's
  history), `probe_loop.sh` (round 2), `probe_loop_r1.sh`,
  `variants-r1.txt`, `variants-r2.txt`, `harness.cr`, `arms/*.patch`.
- `round1/`: each job's summary and runs.csv, the three losses, and two
  stall captures with their Binary Images trimmed.
- `linux/`: progress files and logs of the local runs above.
