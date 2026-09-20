# ivar-layout-roots constructs its red direction per run

**Date:** 2026-09-20 · host: Linux 7.0.0 QEMU · Crystal 1.21.0
Tree after `a6353e9` · `GCRY_LAYOUT_DROP_UNCLASSIFIED`

`make ivar-layout-roots` already ran on x86_64, aarch64 and Darwin, and
already asserted that a module-typed / Proc ivar is covered — by a
precise offset, or by not being a precise entry at all. Its ability to
fail lived in a ROADMAP sentence: drop `has_inner_pointers?` from the
fallback → the entry stays precise and the slot is never scanned.
Nothing in the recipe, the harness or CI constructed that break.

Same shape as `make greg-roots` + `GCRY_DISABLE_GREG_ROOTS` and
`make scheduler-roots` + `GCRY_DISABLE_EC_PINS`: the pre-fix behaviour
is a skip, the gate already has a counter, the recipe requires the skip
to come out red.

## What the knob does

`GCRY_LAYOUT_DROP_UNCLASSIFIED=1` is applied in `apply_env_config`,
*after* `register_builtins`. `Layout.register` then, for a type that
would have fallen back to `scan_cap` because of an unclassified ivar,
installs the precise is_ptr offsets instead. `@name : String` is
emitted; `@payload : Payload` / `@job : Proc` is not.

Applied after builtins on purpose. Fiber#proc is one of the 19 holes
the fallback covers; restoring it at `GC.init` would take the process
down before the harness could re-register its probes. A first version
of the patch materialised `UInt16.new(offsetof)` for every
`force_scan_cap` type, including under `GCRY_AUTO_LAYOUTS=1`, and
overflowed on a type whose pointer ivar sits past UInt16 — the loop
used to be skipped for that class. Offset materialisation stays inside
the drop branch.

Research arm, never a product setting.

## Measured, one binary, two env

`crystal build -Dgc_none bench/ivar_layout_roots.cr -o bin/ivar_layout_roots`

Shipped:

    module  precise?=false scan=[]          leaf live?=true   exit 0
    proc    precise?=false scan=[]          leaf live?=true   exit 0
    control precise?=true  scan=[8, 16]     leaf live?=true   exit 0

`@payload` / `@job` sit at byte 16. `precise?=false` is the scan_cap
fallback. Control emits both `@name` (8) and the Reference-typed
payload (16).

`GCRY_LAYOUT_DROP_UNCLASSIFIED=1`:

    module  precise?=true  scan=[8]         leaf live?=false  exit 1
    proc    precise?=true  scan=[8]         leaf live?=false  exit 1
    control precise?=true  scan=[8, 16]     leaf live?=true   exit 0

    FAIL: the entry for Probe::Holder is precise but neither offset list
          contains @payload at byte 16
    FAIL: the leaf was swept while Probe::Holder.@payload still pointed at it

Same pair for ProcHolder.@job. The holder itself survives (it is in a
global); `holder still points at it: true` with `live?=false` is the
dangling pointer. `--control` is unchanged: that ivar is a Reference,
`force_scan_cap` is false, the knob does not touch it.

`GCRY_AUTO_LAYOUTS=1` arms still pass. The whole-program walk hits the
same `register` macro; without the knob it still falls back.

## Recipe

    __omp_shell("GCRY_LAYOUT_DROP_UNCLASSIFIED=1 $(BIN)/ivar_layout_roots")
    __omp_shell("GCRY_LAYOUT_DROP_UNCLASSIFIED=1 $(BIN)/ivar_layout_roots --proc")

Dropping the skip in `layout.cr` makes those children exit 0, so `!`
goes red. Dropping `has_inner_pointers?` from the fallback makes the
hold arm exit 1. Either rot is visible.

`--control` is not inverted. It must still pass under the knob, which
is what says the harness still roots the holder.

Census: `ivar-layout-roots` was by-hand. The `!` line is the shape
`gate_arm_census.py` already counts. **99 / 35 / 64 → 99 / 36 / 63.**
Not a new gate. The number moved by building an arm on an existing one.

`make knob-doc-check` covers the new `GCRY_*`. Not added to
`windows-typecheck`.
