# scheduler-roots constructs its red direction per run

**Date:** 2026-09-20 · host: this tree's Linux builder · Crystal 1.21.0
Tree after `3eb844f` · `GCRY_DISABLE_EC_PINS`

`make scheduler-roots` already ran on x86_64, aarch64 and Darwin, and
already asserted pin *deltas* derived from `instance_vars`. Its ability
to fail lived in a ROADMAP sentence: stub the pin block → 7 of 16 named.
Nothing in the recipe, the harness or CI constructed that break.

Same shape as `make greg-roots` + `GCRY_DISABLE_GREG_ROOTS` (2026-09-16):
the pre-fix behaviour is a skip, the gate already has a counter, the
recipe just has to require the skip to come out red.

## What the knob does

`GCRY_DISABLE_EC_PINS=1` skips `Fiber::ExecutionContext.unsafe_each` in
`scan_thread_roots` — `pin_ec_ivars`, `pin_ec_root`, the list-node slot.
Thread-level slots (`thread.@scheduler`, `thread.@execution_context`)
still run. Those are not this block, and the gate measures a *delta*.

## Measured, one binary, two env

`crystal build -Dgc_none bench/scheduler_roots.cr -o bin/scheduler_roots`

Hold (shipped):

    pins on a collection before any Parallel EC: 25
    schedulers: 4 (asked for 4)
    pin slots per object: context 12, scheduler 7
    pins with the context up: 78 (delta 53, at least 45 expected)
    Isolated: 18 further pins with it up (at least 15 expected)
    parked fibers still live: 16/16
    exit 0

The 25 "before any Parallel EC" is the default context. Crystal 1.21.0's
default *is* Parallel, so the derived walk already ran on it; the delta
is the harness's own 4-worker context on top.

`GCRY_DISABLE_EC_PINS=1`:

    pins on a collection before any Parallel EC: 4
    pins with the context up: 12 (delta 8, at least 45 expected)
    (a second run: delta 6, pins 10 — leftover Thread-level slots vary
    with how many workers have published when the collection runs)
    Isolated: 2 further pins with it up (at least 15 expected)
    parked fibers still live: 16/16
    exit 1

    FAIL: the Parallel pin block contributed 8 pins where 45 pointer
          ivars are reachable from the context
    FAIL: an Isolated context contributed 2 pins where 15 pointer-ivar
          slots are reachable from it

The leftover 6–8 pins are the Thread-level slots of the workers the
context started — 2 per thread (`@scheduler`, `@execution_context`),
which the skip does not touch. They do not reach 45. Isolated's 2 is
the same pair on its one thread.

`--control` and `--resize` unchanged (delta 0; shrink drops 24 named
pins, 3/3 removed schedulers still have a live reader).

## Survival does not discriminate

Parked fibers 16/16 either way. Named structures 16/16 either way. The
conservative scan of the Thread body and of the worker stacks reaches
them — which is the coverage the pin block exists because it does not
trust (Kemal EC4 SEGV @ …0008). A survival-only assertion would have
stayed green here. The counter is the gate.

## Recipe

    __omp_shell("GCRY_DISABLE_EC_PINS=1 … $(BIN)/scheduler_roots")

Dropping the skip in `collect_scan.cr` makes that child exit 0, so `!`
goes red. Dropping the pin block itself makes the hold arm exit 1.
Either rot is visible.

Census: `scheduler-roots` was by-hand. The `!` + `DISABLE` line is the
shape `gate_arm_census.py` already counts. **99 / 34 / 65 → 99 / 35 / 64.**
Not a new gate. The number moved by building an arm on an existing one.

`make knob-doc-check` covers the new `GCRY_*`. Not added to
`windows-typecheck`.
