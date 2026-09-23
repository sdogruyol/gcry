# Idle RSS: unmap grace was unbounded (2026-09-23)

Host: QEMU x86_64, 12 vCPU, Crystal 1.21.0, headerless default, `-Dgc_none`.
Load generator: `wrk` 4.1.0 from the distro `.deb`, unpacked user-local — this
host has no `wrk` on `PATH`, and a first pass of the Kemal numbers below ran
with none: the script sent wrk's error to `/dev/null` and "after load" meant
"after nothing" (`majors=0` was the tell). Those numbers are discarded.

## The item as filed

`tasks/todo.md`: "post-GC RSS is 27 MB (Boehm 26, master 15) because warm
chunks stay resident; a time-decay release from the monitor thread would lower
idle RSS". Two different things turned out to hold chunks at idle.

## 1. Unmap grace, after a burst — fixed

An emptied bitmap chunk past the warm budget is kept mapped for one cycle and
unmapped at the next major unless a cursor takes it (added against a Kemal
remap churn, `collect_sweep.cr`). The grace had no bound, and an idle process
has no next major.

`bin/probe_burst` (throwaway): build 200 MB of 64 B nodes, drop them, allocate
garbage until two automatic majors have run, idle, then `GC.collect`.

| arm | idle RSS | after `GC.collect` | small mapped at idle |
|---|---|---|---|
| uncapped (`GCRY_UNMAP_GRACE_UNBOUNDED=1`) | **78.7 MB** | 7.0 MB | 77.9 MB |
| capped at one threshold | **22.4 MB** | 6.6 MB | 19.0 MB |
| 50 MB burst, uncapped / capped | 45.9 / 22.4 MB | 6.4 / 6.0 MB | |

Why a cap at the threshold costs nothing: a cycle allocates about one threshold
before the next major, so it cannot take more than that from the graced
chunks; the rest were always going to be unmapped at the next major.

Why two majors: the first major after the drop keeps the *old* threshold's
worth warm (64 MiB) and graces the rest; the second, at the adapted 8 MiB,
unmaps what the first graced but finds the 64 MiB of warm chunks past the new
budget and graces them; a third unmaps them. So the leak is one idle window —
after the second major — and a gate that waited for a third passed both arms.
Still open by the same reasoning: idle right after the *first* major keeps up
to warm + grace at the old threshold (at most 2 x 64 MiB at the clamp).

Steady state is untouched — Kemal `/json`, 10 s x 50 connections, interleaved,
n=10 per arm, one binary:

| | capped | uncapped | delta | t |
|---|---|---|---|---|
| req/s | 44 138 | 44 002 | +0.31% | +0.43 |
| RSS after load | 20 909 kB | 20 898 kB | +0.05% | +0.11 |
| `empty_chunk_grace_kept` | 0 | 0 | | |
| `unmapped_bytes` | 0 | 0 | | |
| `chunks_mapped` | 149 | 149 | | |

Grace never engages in this steady state, so the cap cannot act on it.

Gate: `make idle-rss-after-burst` (`bench/idle_rss_after_burst.cr`) — the empty
chunks the last sweep left mapped (`fully_free - released - dormant`) must fit
`warm + threshold`; shipped 16 777 216 = bound, uncapped 75.4 MB, 58.6 MB over.
Exact by construction, so no margin to tune. An earlier bound on the whole
small mapping passed by one chunk in an unoptimised build, and before that
the burst stayed live in one (a debug frame slot held the list head).

## 2. The warm budget, at steady-state idle — still open

Kemal `/json` under load, then idle (n=2 each):

| | after load | idle 60 s | after `/gc-collect` |
|---|---|---|---|
| gcry | 21.1 MB | 19.9 MB | 13.3 MB |
| Boehm | 14.5 MB | 13.4 MB | 13.4 MB |

gcry idles 6.6 MB above its own floor and ~1.5x Boehm's idle: that is the warm
budget (`fully_free_chunk_bytes` 7.6 MB, warm retain 8 MiB), kept on purpose so
the next cycle does not fault its chunks back in. Releasing it when idle needs
a clock — nothing in gcry runs without an allocation to drive it — and that is
the design the todo item names.

## 3. The clock: `GCRY_IDLE_RELEASE_MS` (opt-in)

### First version: release pages without a collection — replaced

A raw pthread turned empty, cursor-free bitmap chunks dormant under the
chunk-list lock and `MADV_DONTNEED`ed them. Sound (checksum gate PASS 3/3,
unchecked red arm FAIL 3/3), and after a burst it reached the floor
(21.4 -> 5.6 MB). On Kemal it returned only ~2 of the ~7 MB (-9.5%, t=-4.2):
the rest is garbage allocated since the last major, whose `occ` bits stay set
until a sweep. Only a collection reclaims that.

### What other collectors do

Boehm has no clock: memory goes back only during collections, once a block has
been free for `GC_unmap_threshold` (6) collections, and not even on explicit
`GC_gcollect` unless `GC_FORCE_UNMAP_ON_GCOLLECT` is set
([bdwgc macros.md](https://github.com/bdwgc/bdwgc/blob/master/docs/macros.md)).
Go forces a GC after two minutes without one and scavenges in the background
([golang/go#37116](https://github.com/golang/go/issues/37116)); G1 has a
periodic collection, off by default
([JEP 346](https://openjdk.org/jeps/346)); ZGC uncommits after 300 s, on by
default ([ZGC wiki](https://wiki.openjdk.org/spaces/zgc/pages/34668579/Main)).
The design that reaches the floor is Go's and G1's: collect when idle.

### The idle collector

Why not from a raw pthread: the collection needs the current Crystal thread in
~15 places (`stop_world` skips `Thread.current`, root scans read
`Fiber.current`), and on a raw pthread `Thread.current` *creates* a `Thread` —
allocating and pushing onto the list the stop walks. So `gc-idle` is a Crystal
thread (`Thread.new`, `nanosleep` loop) calling `Heap#idle_collect`, i.e.
`collect(release_warm: true)`, once per idle stretch. Three things kept it from
being an ordinary thread, each found by measurement:

1. **Not a mutator.** `multi_mutator_threads?` counts `Thread.unsafe_each`
   past 2; one more thread would move a single-threaded program onto the
   multi-mutator sweep, which disables empty-chunk release. Excluded.
2. **Finalizers.** They run on the collecting thread, and this one has no
   scheduler. Its collections leave them queued; the first version left them
   for the next *ordinary* collection, and idle collections made those rare:
   3 of 41, with 2 999 of 8 000 finalizers run against 7 799 off. Now the
   next slow-path allocation runs them (`maybe_collect`, before any lock):
   7 796-7 799.
3. **Suspension.** On Crystal's list it was signalled and waited for at every
   stop: pause p50 **+19% (t=+6.8)** on Kemal. It is signal-exempt now, like
   the Monitor, and qualifies more strictly: between collections it only reads
   (`Heap#allocation_activity`, no crediting), it waits out another thread's
   stop before collecting, and its stack is not scanned (no GC references;
   its Thread and fiber are on Crystal's lists). Darwin suspends it with Mach
   `thread_suspend` like every thread.

Kemal `/json`, one binary, knob off/on interleaved, n=8 each (250 ms), final:

| | on | off | delta | t |
|---|---|---|---|---|
| idle 5 s | **14.2 MB** | 20.4 MB | -30.0% | -52.6 |
| idle 1 s | 14.5 MB | 20.8 MB | -30.1% | -29.7 |
| pause p50 | 377 us | 375 us | +0.5% | +0.21 |
| req/s | 43 673 | 43 306 | +0.9% | +0.77 |
| after load | 20.93 MB | 20.92 MB | +0.02% | +0.05 |
| after `/gc-collect` | 13.45 MB | 13.39 MB | | |

Two changes landed after this table, neither on Kemal's path: the TLAB refill
fix below (TLAB is off there) and the `GC.disable` re-check (one branch under
a lock the idle cycle already takes). Not re-measured.

Idle lands ~0.8 MB above the `/gc-collect` floor and ~0.8 MB above Boehm's
idle (13.4 MB), from 7 MB above.

Gate: `make idle-release` (`bench/idle_release.cr`) — checksummed live set,
40 bursts separated by 1-2x idle gaps; requires idle collections, the last of
which released every empty chunk (`fully_free - released - dormant == 0`),
intact objects, finalizers at least as prompt as without the knob and none on
the idle thread. Shipped: PASS (36-39 idle collections of 41). Red arm, the
same binary without the knob: FAIL ("no collection ran at idle"). By hand:
removing the deferred-finalizer run fails it (4 599 of 7 600 due), and letting
the idle collection run finalizers fails it (7 593 on the idle thread).

### Stress with the knob at 5 ms: two defects, one test assumption

Every gate runs with the knob off, where each new line is inert. So the
multi-threaded suites were re-run with `GCRY_IDLE_RELEASE_MS=5`, which makes
idle collections overlap everything:

1. **TLAB refill raised `OutOfMemoryError` with memory to spare** — a defect
   that predates this work. `stw_mt_property_test --tlab` (header layout,
   freelist) failed 3 of 3. Split: `release_warm` off still failed;
   suspending the idle thread (no signal exemption) passed 3 of 3. The cause
   is `tlab_refill`: after one miss it gave up whenever `@collecting` was
   true, and `@collecting` is heap-wide and stays true through the post-STW
   phase while every other thread runs — so a miss there (a dormant revive
   refused mid-walk) became an OOM. The idle thread's background cycles
   overlap allocation, which is what exposed it. Now it gives up only when
   the calling thread is the collector; any other thread collects, which
   waits out the cycle in flight. 5 of 5 seeds with the knob, 3 of 3 without.
2. **The idle collector ignored `GC.disable`.** Checked only before asking
   for the post-STW lock, it could wait on that lock through the program's
   own collections and then run inside a window the program had disabled.
   Now re-checked under the lock (`run_collection_body`, `idle: true`). The
   harness disables GC for 4x the idle time and requires no idle collection;
   removing the checks fails it.
3. **`process_spec/regression/1_live_objects_dormant_spec.cr`** read 1-22
   objects short of `baseline + count` in 23 of 30 full-suite runs. A probe
   with the same window shape: short in 30 of 30 rounds *only* when an idle
   collection landed in the window, by at most the 40 objects made just
   before the baseline, and all 300 000 rooted blocks intact; knob off, never.
   The spec's arithmetic assumes no collection in that window, so it now
   says so with `GC.disable` around it: 0 of 30 with the knob, after (2).

Limitation, stated: the thread starts at the end of the first collection,
because `Thread.new` before the runtime is up is a known crash
(`gc_override.cr`). A process that has never collected has no idle
collector — and less than one threshold (8 MiB minimum) to give back.

## 4. On by default at two minutes

Decided 2026-09-23: `GCRY_IDLE_RELEASE_MS` defaults to 120 000 on Linux and
Darwin (Go's forced-GC period; ZGC uncommits after 5 min, G1 leaves periodic
GC off), `=0` turns it off. Every process-GC program now has a `gc-idle`
thread after its first collection, so every Linux CI target was re-run with
it on — and the one that counts per-thread scan work found a cost the Kemal
numbers could not show:

**`make stw-slot-precision` failed**: 16 fiber stacks scanned from the guard
page in 8 collections, where the collector's own fiber accounts for 8. On the
multi-mutator path every *running* fiber is scanned from its thread's recorded
SP, and the idle thread — signal-exempt on Linux — has none, so its fiber fell
back to a full 8 MiB guard-to-bottom scan every collection. Kemal never takes
that path (single mutator), which is why its pause p50 did not move. The idle
fiber is skipped now (no GC references on it; the fiber object itself is still
marked): 8 guard scans in 8, and the harness's per-collection time went from
40.75 ms to 23.12 ms at 96 threads.
