# `GCRY_DISABLE_AUTO_LAYOUTS` was an orphan, and `ivar-layout-roots` could not see it

2026-09-20, this host (x86_64, Linux, Crystal 1.21.0), `-Dgc_none`,
headerless default.

The orphan-knob census (`../2026-09-16-orphan-break-knobs/`) left
`GCRY_DISABLE_AUTO_LAYOUTS` among the knobs `src/` reads and no spec, recipe
or CI step exercises. `ivar-layout-roots` already runs under
`GCRY_AUTO_LAYOUTS=1`, which looks like coverage. It is not.

## Why that gate cannot see the knob

Those arms also call `Gcry.register_layout` on their probe types. The disable
skips `Gcry.register_layouts` (the whole-program walk) and leaves the explicit
registrations in place, so the probes stay registered either way. And a
survival assertion would not discriminate even if they did not: the
conservative body scan reaches the same words. That is the same lesson as
`GCRY_DISABLE_GREG_ROOTS=1` on `greg-roots` — the victim survives the break;
the counter is what goes red.

## Measured

`bench/auto_layouts.cr`, three child arms of one process, same binary:

| arm | knobs | `layout_entries` | `AutoLayoutProbe` registered |
|---|---|---|---|
| builtins | (none) | **51** | false |
| auto | `GCRY_AUTO_LAYOUTS=1` | **159** | true |
| disabled | both | **51** | false |

`AutoLayoutProbe` is a concrete `Reference` this file declares, with a
`String` ivar so `register` installs a precise entry. `register_builtins`
does not name it. That is the second counter: a larger table that still
missed a type this program can see is not the opt-in doing what
`docs/HARDENING.md` says.

## Red direction, observed

The disabled arm's env with `GCRY_DISABLE_AUTO_LAYOUTS` dropped, same
binary, same assertions:

    FAIL: disabled: … layout_entries=159 against builtins 51
    FAIL: disabled: AutoLayoutProbe is still registered

Both counters, both red. Restored, the gate exits 0 again.

## What this does not claim

It does not say a precise layout is load-bearing for a root. Conservative
scan covers the same words; this gate asserts that the opt-in *installs*
what it claims and that the disable *undoes* it. Rot of either is a knob
that silently does nothing, which is this census item's disease.

The remaining orphans `GCRY_POOLED_STACK_NOROOT`,
`GCRY_MAPS_INFLIGHT_NOROOT`, `GCRY_BIRTH_GRACE_NOROOT` are default-off
research paths. Their rot is not production soundness; they are not called
root loss here. `GCRY_DISABLE_SCRUB_FIBERS` is the other production-ish
orphan (`GCRY_SCRUB_FIBERS` is opt-in).

Census after this gate: **98 / 33 per run / 65 by hand** (was 97 / 32 / 65).
