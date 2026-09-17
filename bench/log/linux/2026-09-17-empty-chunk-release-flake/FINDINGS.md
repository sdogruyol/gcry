# The aarch64 spec flake family: one extra thread turns the release path off

**Date:** 2026-09-17 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `6171a30` · Crystal 1.21.0

`spec/dormant_revive_spec.cr` has carried this note since it was written:

> this example and four others like it have failed together on
> `test (aarch64 native)` three times in about thirty runs while passing 80 of
> 80 locally, and "expected > 0" says nothing about which of dormancy's
> preconditions was missing on that host

It said "four others like it" and it was right about the count. Root cause
below, and it is not timing.

## What the widened state dump answered

The dump was widened on 2026-09-17 after a kcov occurrence, precisely because
it could not tell three failures apart. The next occurrence — `test (aarch64
native)` on `6171a30`, five examples across three files — printed:

    no chunk went dormant — chunks=8 dormant=0 dormant_bytes=0 fully_free=1048576
    unmapped=0 live_objects=0 heap_size=1048576 retain=67108864 warm_retain=0
    page=4096 compiled_page=4096

Every candidate but one dies on that line:

| candidate | ruled out by |
|---|---|
| chunks were never empty | `fully_free=1048576` — all 8 were seen fully free |
| something was still live | `live_objects=0` |
| warm retain preempted dormancy | `warm_retain=0` (pinned hours earlier) |
| dormant budget too small | `retain=67108864`, 64 MiB against 1 MiB of empties |
| they were unmapped instead | `unmapped=0` |
| `madvise` alignment | `page=4096 compiled_page=4096` |

What is left: the release path **did not run at all**.

## It is the process's thread count

    private def release_empty_chunks_this_collect? : Bool
      return false unless @release_empty_chunks
      return true unless sweep_multi_mutator?
      @parallel_empty_chunk_dormant || @parallel_empty_chunk_munmap
    end

`sweep_multi_mutator?` falls through to `multi_mutator_threads?`, which counts
Crystal's thread list. Both parallel knobs default to false. So **in a process
with more than one mutator thread the empty-chunk release is off**, and
`munmap_empty_chunks_this_collect?` is gated the same way.

A spec process's thread count is not the example's to control. One thread left
running — or still winding down — from another example flips it, and the
randomised order decides whether that happens. That is why it fails ~3 in 30 on
a slower host, passes 80 of 80 locally, and showed up under kcov: all three are
"how long another example's thread is still alive".

## Reproduced, both paths

One extra live thread, nothing else changed:

| arm | dormancy | munmap |
|---|---|---|
| no extra thread, knobs off | `dormant=8` | `unmapped=393216` |
| **extra thread, knobs off** | **`dormant=0`** | **`unmapped=0`** |
| extra thread, knob on | `dormant=8` | `unmapped=393216` |

The middle row is the CI failure line byte for byte, including
`fully_free=1048576` and `chunks=8`. The third row is identical to the first:
the knobs restore the single-mutator behaviour exactly, because they are only
read on the multi-mutator branch.

## Fix

Every spec that turns on `release_empty_chunks` now also pins
`parallel_empty_chunk_dormant` and `parallel_empty_chunk_munmap` — **eight
sites** across six files, not the five that happened to fail. The other three
were exposed to the identical flake and had not been caught yet.

This changes nothing about what the examples measure: on the single-mutator
branch `release_empty_chunks_this_collect?` returns true before either knob is
read. What it removes is the process's thread count as an input to the
assertion.

## What this does not settle

The two knobs exist because post-STW munmap under Parallel was rejected for the
**process GC under load** (SEGV and a throughput cliff, per
`collect_scan.cr`'s note). Setting them in a spec that drives a library heap
with a synchronous `collect` is not that configuration, but it is worth saying
that these examples now exercise the parallel branch on any host where another
example leaves a thread running — which is a slightly different code path from
the one they were written against, and the right one to be testing given they
ask for a release.

Whether the same gate is load-bearing anywhere a *user* would notice is a
separate question this does not touch: a process GC with more than one mutator
thread does not release empty chunks unless `GCRY_PARALLEL_EMPTY_CHUNK_DORMANT`
or its munmap sibling is set, which is documented behaviour and measured RSS
policy, not a defect.


## The fifth spec had a different predicate — 2026-09-17, after the pin

The knob pin above covered four of the five specs
`bench/log/linux/2026-09-13-report-stack/FINDINGS.md` had listed as the aarch64
family. The fifth, `live_object_checks`, failed on the two runs *after* the pin
landed (`6171a30`, `8ba3660` — a probe commit and the pin itself, neither
touching the collector) with:

    1) Gcry::Invariant does not count blocks in chunks the sweep made dormant
       Expected 0 to be GreaterThan 0          # spec/invariant_spec.cr:137
    2) Gcry::Invariant catches a live_objects drift, and says how many walks ran
       Expected 0 to be GreaterThan 0          # spec/invariant_spec.cr:197

Same *shape* as the other four — a predicate over Crystal's thread list decides
whether a path runs — but a different predicate, which is why pinning the
empty-chunk knobs did nothing for it. `check_live_objects` returns early and
counts a `concurrent_skip` when `concurrent_mutators?` is true, and that is
`multi_mutator_threads?`: a count of the thread list against a constant. Three
threads on the list and the walk does not run, so `live_object_checks` stays
where it was.

Reproduced directly rather than waited for, on Linux x86_64:

| threads on Crystal's list | `concurrent_mutators?` | `live_object_checks` | `concurrent_skips` |
|---|---|---|---|
| 4 (two workers running) | true  | 0 → **0** | 0 → 1 |
| 2 (workers joined)      | false | 0 → **1** | — |

The first row is the CI failure exactly. The trigger is that
`invariant_spec.cr:150` starts two workers *on purpose* to force the skip, and
`Thread#join` returning does not mean Crystal has unlinked them yet — in a
randomised order the next example reads three mutators and skips. Locally the
list drained 4 → 2 by the time `join` returned, which is why 80 local runs never
showed it and a loaded aarch64 runner shows it one run in two.

**Fixed by having the examples establish their own precondition**
(`SpecSoleMutator.wait` in `spec/spec_helper.cr`): wait for the list to drain,
and if it never does, say *that* instead of failing on the walk counter. Waiting
rather than a knob or an override, because the threads are already joined — what
lags is the unlinking, not a live mutator, so there is nothing to override.

**Not proven:** that the aarch64 runs go green. The mechanism and the fix are
measured here; the flake's rate was one run in two on a platform this host
cannot reproduce, so only repeated CI runs can say. The `concurrent_skips`
example at `:150` is the red direction and still asserts the skip happens.


## Waiting for the thread list was the wrong fix — corrected same day

`SpecSoleMutator.wait` (06fb325) assumed the list drains after `Thread#join`
returns, because it did here: 4 → 2 immediately. On the aarch64 runner it does
not. Run 35240604177, `test (aarch64 native)`, two errors:

    3 threads are still on Crystal's list after 5.0s, so check_live_objects will
    count a concurrent skip instead of walking.

So the helper turned an intermittent failure into a deterministic one on the
platform that had the flake. The premise was wrong and the mechanism with it:
`join` returning says the thread finished, not that Crystal has unlinked it, and
`multi_mutator_threads?` trips above **two** threads — a spec process that keeps
an extra pool thread alive sits over that line permanently.

**Replaced with a predicate instead of a wait.** `Heap#invariant_sole_mutator`
says "no other thread can reach this heap", and `check_live_objects` then does
not let `concurrent_mutators?` — a count of the *process*'s threads — veto a
walk over a heap that is private to the caller. Both examples own a
`Gcry::Heap.new`, so it is true by construction. The two-instant race the skip
exists for is still caught: the confirm loop skips on `reported != after`.

Reproduced and verified locally, five threads on the list so
`concurrent_mutators?` is true either way:

| heap | `live_object_checks` across one malloc + one explicit check |
|---|---|
| without the predicate | **+0** — the aarch64 failure exactly |
| with the predicate    | **+2** |

No waiting, no host dependence, and `invariant_spec` passes five runs in a row
locally.
