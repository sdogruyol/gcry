# A v0.20.0 root fix that shipped with no gate, and the harness it needed

**Date:** 2026-09-16 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `dbf168a` · Crystal 1.21.0 · `bench/dead_stack_root.cr`

The orphan-knob matrix (`../2026-09-16-orphan-break-knobs/`) ended with seven
knobs no gate notices, and said the reason was that no harness constructs the
condition they break. This is the first of those conditions built.

## What had no gate

`Thread#dead_fiber_stack` parks a terminating fiber's stack on the thread,
because Crystal cannot release a fiber's stack until it swaps away. While it sits
there the thread may still be running on it and the owning `Fiber` is already off
`Fiber.unsafe_each` — which is how gcry finds fiber stacks. `scan_dead_fiber_stacks`
in `src/gcry/unowned_stack_roots.cr` is the v0.20.0 answer, credited with taking
the nested-spawn repro from **11/24 crashes to 0/24**.

Nothing gated it:

| | |
|---|---|
| `GCRY_DEAD_STACK_ROOTS=0` (its disable) | in no `spec/`, no recipe, no CI step |
| `dead_stacks_walked` / `dead_stack_words` | printed by `bench/nested_spawn_uaf.cr`, asserted nowhere |
| `make nested-spawn-uaf` | *"Not a gate: it fails most runs on purpose"*, and not in CI |

So `scan_dead_fiber_stacks` could have regressed to a no-op and every gate in the
tree would have stayed green.

## `make dead-stack-root`

Four arms. The victim is allocated on the **main** fiber and only its obfuscated
address crosses into the dying one, where `plant` XORs it back and fills 512
stack words — inside `UNOWNED_STACK_WINDOW`, the 64 KiB from the top that the
collector walks, and the region where every hit of the 2026-08-17 address-space
audit sat (968–1408 bytes below the top).

| arm | config | walked | victim | required |
|---|---|---|---|---|
| hold | default | 2 | **live** | survives |
| `--control` | default, address never planted | 2 | dead | dies |
| `--noroot` | `DEAD_STACK_ROOTS=0 DEAD_STACK_NOROOT=1` | 2 | dead | dies |
| `--disabled` | `DEAD_STACK_ROOTS=0` | **0** | dead | dies, and the walk must not happen |

Three of four require the victim to **die**, so the red direction is constructed
every run rather than recorded in prose. `--disabled` also asserts `walked == 0`,
which is how it checks the knob still gates the walk and not merely the offer.

## Two things the harness got wrong first, and the arms caught both

**The control arm failed on the first version.** The victim was allocated *inside*
the dying fiber, so `GC.malloc`'s return value and the local holding it left
plaintext copies in that fiber's own frames — and the dying-stack root then
retained the victim whether or not `plant` ran. The control arm reported exactly
that: *"something else in this process retains it and neither arm can
discriminate"*. Allocating on the main fiber and passing only `addr ^ KEY`, with
the XOR performed under `plant_it`, fixed it. Both arms now touch the same 4 KiB
of stack and store the same number of words; only the *value* differs, so a
difference in survival cannot be a difference in frame size.

This is `bench/greg_roots.cr`'s documented trap in a new place: keeping a pointer
out of memory is a codegen outcome no source-level test can compel. There the
answer was to gate on a counter; here it is to never compute the plaintext.

**`GCRY_DEAD_STACK_NOROOT=1` alone is not the twin arm.** The walk takes
`offer = @dead_stack_roots`, so with the fix at its default the knob walks *and*
offers: measured, the victim survives. The twin is
`GCRY_DEAD_STACK_ROOTS=0 GCRY_DEAD_STACK_NOROOT=1`. `docs/HARDENING.md` described
it as "its twin — same walk, roots nothing" with no mention of needing both, and
is corrected. The harness refuses the one-flag form with exit 64 rather than
measuring it, because that form is the shipped fix with an extra flag set.

## What this does not claim

It is not the 2026-08-17 defect. That was a dying `Deque(Fiber::Stack)` buffer
freed while a thread still used it. This asserts the *coverage mechanism* shipped
in response — a word on a parked dying stack is a root — which is the part a
regression would remove silently.

And the victim here is semantically garbage: the fiber that referenced it has
returned. Retaining it is what rooting a dying stack *does*, and conservative
retention of a stack the thread may still be running on is the trade the fix
makes. "Survives" is the contract under test, not a leak.

## Census

Adding this gate moved the census 84 → 85 and exposed a flaw in the census
itself: with only its first two criteria (`!`/`grep -q`, or a forked child) it
counted `dead-stack-root` as "by hand" despite three arms requiring a death. The
third criterion — the recipe re-running the harness under a breaking knob or
flag that the harness judges, with `--control` excluded because a control must
pass — now counts it. Same tree, **30 per run / 55 by hand** of 85 against the
20/64 reported hours earlier. The definition moved, not the tree, and the earlier
record is corrected in place.
