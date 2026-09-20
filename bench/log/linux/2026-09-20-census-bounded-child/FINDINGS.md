# The census missed BoundedChild.run, which is how this repo forks

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `acb7d72` · `python3 bench/gate_arm_census.py`

The number this program quotes is re-derived from `bench/gate_arm_census.py`.
On 2026-09-16 the tool under-counted `make dead-stack-root` because its first
two criteria did not see a recipe arm that requires the victim to die. The
same class of miss, again: the fork detector looked for `Process.run` and
this repo does not fork that way.

`BoundedChild.run` is a `Process.new` with a deadline, written after a hung
child took an aarch64 job down (run `32645403155`). `make stw-epoch` forks
with `Process.new` directly. Neither matched. Twenty-one gates that already
construct a red arm every run were counted "by hand, once", and the leftover
63 was being read as work still to do.

## What changed in the detector, not in the gates

- Forks: `Process.run|Process.new|run_child|spawn_child|BoundedChild`.
- Judges: `failures <<` *or* `failures +=` — `make stw-slots-grow-race`
  uses the latter and `exit StwSlotsGrowRace.main`.
- Breaks: also `--overshoot` (`make scrub-margin`'s ladder).
- A harness named only in a `--cross-compile` recipe is compiled, not run.
  Without that, `darwin-typecheck` / `windows-typecheck` would inherit a
  red arm from a file they never execute.
- Restoring-knob regex: the names `docs/HARDENING.md` already calls a red
  arm (`NO_EVICT`, `FREE_OLD`, `SKIP_WHEN_BUSY`, `FIXED_SLOTS`,
  `BOUNDED_RESUME`, `ROOT_LAZY`, `LATE_CLEAR`, `UNCHECKED`) and the flags
  `--lazy`, `--no-evict`, `--overshoot`, `--nogrow`. `--control` still
  does not count.

Nothing in a recipe, a harness, or CI was added. The criteria were the
documented ones; the detector did not implement them.

## Census

```
harness-driven gates:              99
red direction constructed per run: 57
red direction established by hand: 42
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 36 / 63 → 99 / 57 / 42.** Same tree.

### Moved, because the harness already forked

`chunk-search-race`, `darwin-stw-resume`, `explicit-collect-barrier`,
`find-block-race`, `large-cache-race`, `live-graph-audit`,
`monitor-gate-deadlock`, `oom-no-hang`, `scrub-margin`,
`stack-bounds-growth`, `stw-ack-window`, `stw-capture-coverage`,
`stw-epoch`, `stw-index-race`, `stw-slot-precision`,
`stw-slots-grow-race`, `stw-startup-hang`, `thread-churn-uaf`.

`thread-startup-cost` moved with them. It is a probe, not a gate — it
asserts that its arms ran and otherwise reports numbers — and the
`--child` heuristic cannot tell. The classification is approximate in
both directions; this is the over-count the docstring now names.

### Moved, because the recipe already ran the restoring knob

`make thread-staging` (`GCRY_STAGED_NO_EVICT=1 --no-evict`) and
`make darwin-static-root-init` (`GCRY_STATIC_ROOT_LAZY=1 --lazy`). The
third criterion has said this counted since 2026-09-16; the regex did
not contain those names.

Type-check targets stayed by-hand. That is the `--cross-compile` guard
working, not a remaining hole.

## What the leftover 42 actually is

Most of it cannot grow a restoring knob: property tests, fuzz, soak,
`*-typecheck`, probes that only report (`fiber-lag-cost`, `pause-budget`,
`pool-refill-cost`, `rss-leak`). `make thread-census-symbolize` is
counted by hand on purpose — its red direction is a missing `addr2line`
or an unresolvable offset.

Still a real gap, in CI, whose red direction is a hand edit or a swallowed
exit: `mark-clear-index` (`--control` is the defect arm and is excluded
by design), `nested-spawn-uaf` (the original repro; `dead-stack-root` is
the gate), `occupied-release` (recipe prefixes both arms with `-`, so
make cannot go red). Those are the next arms, not another pass on the
detector.

The three remaining orphan knobs (`POOLED_STACK_NOROOT`,
`MAPS_INFLIGHT_NOROOT`, `BIRTH_GRACE_NOROOT`) are still default-off
research paths. Rot there is not production soundness.
