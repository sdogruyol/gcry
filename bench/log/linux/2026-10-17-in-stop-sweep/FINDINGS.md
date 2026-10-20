# The in-stop sweep dropped the chunk list behind a frozen mapper (2026-10-17)

Fix: `272d73e5` ("sweep: the in-stop rebuild leaves the chunk list alone
while a frozen thread holds its lock"), docs `01b184a6`. CHANGELOG
`[Unreleased]` → Fixed, ROADMAP (the in-STW sweep against a frozen list
writer). Spec: `process_spec/regression/75_stop_sweep_frozen_mapper_spec.cr`.

The runs below were made locally from a scratch worktree whose logs were
not kept; the numbers are those the investigation reported when the fix
landed, and only spec 75 can be rerun from this tree. The harness is
`bench/claim_stress.cr` (`make claim-stress`), in the tree since 0.38.0;
it was then on branch `occupancy-plain-or` (`95e73e39`, since deleted).

## Root cause

`map_chunk` reads the list head and stores `@chunks = new` with `new.next`
that head, under `@chunk_list_lock`. With the sweep inside the stop
(`GCRY_DISABLE_LAZY_SWEEP=1`, `GCRY_PAGE_DONTNEED=1`, `GCRY_TLAB=1`,
`GCRY_INCREMENTAL=1`, or `parallel_empty_chunk_munmap`), the sweep rebuilt
`@chunks` without that lock, reversing it, so the old head became the tail.
A mapper the stop froze between its head read and its store finished after
`start_world`, leaving the list two chunks long: the new chunk and the old
head. Every other chunk stayed in `@chunk_index` and off the list: never
swept again, its blocks counted live and its capacity counted free for
good. `chunk_back_link_faults` stayed 0 in every run; the relinked-chunk
publish, the pending-empty flush and the large back-links were not
involved. An `unlink_chunk` frozen mid-surgery is the same kind of hazard
and never showed up.

## Instrumentation

A diagnostic build of the base tree recorded, at each in-stop sweep, which
thread held `@chunk_list_lock` and at which site, and whether the
index-minus-list deficit grew by the next one. Every loss followed a stop
that froze `map_chunk` right after its head read: 3 of 3 such stops lost
chunks, and 0 of 9 stops that froze a list reader did.

## claim_stress, before and after

Base tree `e8c0327e` (release-0.37.0 before the fix); fixed tree
`272d73e5`. 2-second runs, Parallel, in-stop sweep
(`GCRY_DISABLE_LAZY_SWEEP=1`) unless noted. The 40 base runs include 20 of
the diagnostic build; seeds were not recorded.

| tree   | arm                    | runs that lost a chunk or drifted                                      |
|--------|------------------------|------------------------------------------------------------------------|
| base   | in-stop, 2 workers     | 14 of 40: 31–252 chunks, drift −331 to −9 084 objects, −3.7 to −30 MB free bytes |
| fixed  | in-stop, 2 workers     | 0 of 20                                                                |
| fixed  | in-stop, 4 workers     | 0 of 10                                                                |
| both   | lazy (default), 4 workers | 0 of 10 each                                                        |

The fixed runs declined the relink (`stop_sweep_relinks_declined`) 0–9
times in about 1 250 collections a run. One base run drifted −2 697
objects with no chunk off the list, a different signature, not
investigated.

## The other set of numbers

`bench/log/linux/2026-10-17-occupancy-claim/FINDINGS.md` (then on the
branch, in the tree since 0.38.0) reports the same bug on the same base tree
`e8c0327e`: 5 of 10 seeds (1–10) of `claim_stress --workers=2`, 2 s, with
35–50 chunks unlisted and drift −618 to −6 884 objects, −4.1 to −5.8 MB
free bytes (3 of 10 on that branch's own tree), and none under the lazy
sweep. Those runs were a separate harness copy, with the claim-only
counters the base tree lacks stubbed out, on fixed seeds 1–10, and no
diagnostic build. The runs above used another copy of the harness with the
diagnostic fields added, 40 runs half of them on the diagnostic build, and
unrecorded seeds. Both show the same signature (chunks indexed and off the
list, no drift in a run without one, the lazy sweep clean); the rates and
ranges differ with the build and seeds, and neither set is a measure of
how often the bug strikes outside this harness.

## Default configurations

No default sweeps in the stop: Parallel, EC4 and EC1 sweep after the world
and publish under the lock, on both layouts (read from
`sweep_after_world?`, the `lazy_sweep` setters and `gc_override.cr`). Only
the Parallel lazy arm was run (the table above); EC4, EC1 and the header
layout were checked by reading the code, not run under the harness.

## Fix and spec

The in-stop sweep takes `@chunk_list_lock` with a try-lock and holds it
until the rebuilt list is stored; when a frozen thread holds it, the sweep
leaves the list as it is, queues no empty chunk for munmap and counts
`stop_sweep_relinks_declined`. `chunk_publish_hook` parks a mapper between
the head read and the store; `stop_sweep_list_lock = false` restores the
old code as a control.

Spec 75 parks a mapper there across a `GC.collect` with lazy sweep off,
each arm in a child process: 0 chunks lost with the fix, 55 on the control
arm, in each of 3 checks (the spec itself asserts only 0 and more than 1).
