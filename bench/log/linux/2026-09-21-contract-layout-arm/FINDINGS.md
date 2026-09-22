# `make compiler-gc-contract` runs once with layouts off and must fail — and what the last three are

**Date:** 2026-09-21 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `2e6f26f` · `python3 bench/gate_arm_census.py`

## `compiler-gc-contract`

Twelve checks on the GC API and the compiler contract (`@crystal_type_id`
in the header, `Array`'s type_id registered for layout scanning). One of
them has a subject the collector can switch off: `GCRY_DISABLE_LAYOUT=1`
registers no layouts, and "Array type_id is registered for layout" fails
— **1 failed, 11 passed**, exit 1. The recipe requires that (`!`); the CI
step goes through the recipe, which already ran the two `crystal tool`
checks the step duplicated.

## The three left owed an arm, read honestly

`oom-test`, `thread-storm` (and their shorts):

- **`oom-test`**'s phase 2 passes when it *cannot* trigger OOM ("system
  memory sufficient" is a PASS), phase 3's finalizer count is a note, and
  phase 1 can fail only on an exception. The property it names — running
  out of memory is reported, not a hang — is `make oom-no-hang`'s, which
  caps `RLIMIT_AS` in a child, requires the error, and counts a killed
  child as the failure. That gate constructs its red per run already.
- **`thread-storm`** allocates atomic memory from threads that come and
  go and asserts no exception. Nothing it holds can be lost by a root
  knob (nothing has pointers), and the defect that shape reaches — a
  block reissued while a dying thread still uses it — is `make
  thread-churn-uaf`'s, whose `GCRY_SWEEP_MUTATOR_LATCH=0` arm fails 5 of
  18 guarded and 14 of 18 poisoned. An arm here would duplicate that one
  with a worse rate.

Both are smokes whose red is a crash, beside a gate that already owns the
defect. They are recorded with the fuzz and property families rather than
given an arm that would test the arm.

## Census

```
harness-driven gates:              100
red direction constructed per run: 79
red direction established by hand: 21
```

**100 / 78 / 22 → 100 / 79 / 21.** The 21: 11 fuzz / property
defect-finders, 2 compile-only typechecks, 4 research targets, and the
4 smokes above (`oom-test`, `thread-storm`, with shorts) whose defect has
its own gate.
