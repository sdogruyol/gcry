# Eleven knobs that break a root path, and what notices them

**Date:** 2026-09-16 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `cbc6844` · Crystal 1.21.0

Yesterday's census (`../2026-09-16-gate-arm-audit/`) found that 64 of 84 gates
have a red direction only because someone once broke them by hand. The follow-up
question is cheaper than it looks: **the pre-fix behaviour many of those gates
need is already a knob in the collector.** If a knob exists, the red arm costs a
recipe line and no production code.

## The orphans

Every `GCRY_*` the collector reads is in `docs/HARDENING.md` — `make
knob-doc-check` has enforced that since the reference drifted by 33. Nothing
enforces that a knob is *used*. Eleven root-disabling ones are read by `src/` and
appear in no spec, no `bench/`, no Makefile recipe and no CI step:

    GCRY_DISABLE_GREG_ROOTS    GCRY_DEAD_STACK_NOROOT      GCRY_STACK_BOUNDS_NOGROW
    GCRY_DISABLE_STATIC_ROOTS  GCRY_POOLED_STACK_NOROOT    GCRY_DISABLE_SP_CLAMP
    GCRY_DISABLE_AUTO_LAYOUTS  GCRY_MAPS_INFLIGHT_NOROOT   GCRY_DISABLE_SCRUB_FIBERS
    GCRY_DISABLE_LAZY_SWEEP    GCRY_BIRTH_GRACE_NOROOT

`ROADMAP.md` says of one of them — `GCRY_STACK_BOUNDS_NOGROW` — that it is
"gated in `process_spec` … (red at `visited=150 read=130`)". It is not in
`spec/` at all. That claim is stale.

## Which gate notices which knob

Each knob set to 1 against every fast root gate, exit status recorded. `11` is a
dead process, `124` is `timeout` at 90 s, baseline row is all zeros:

| knob | greg | sched | bss | birth | ivar | tls | mark |
|---|---|---|---|---|---|---|---|
| `GCRY_DISABLE_GREG_ROOTS` | **1** | 0 | 0 | 0 | 0 | 0 | 0 |
| `GCRY_DISABLE_STATIC_ROOTS` | 11 | 11 | **1** | 11 | 11 | 11 | **1** |
| `GCRY_DISABLE_SP_CLAMP` | *124* | *124* | 0 | 0 | 0 | 0 | 0 |
| `GCRY_DEAD_STACK_NOROOT` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `GCRY_POOLED_STACK_NOROOT` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `GCRY_MAPS_INFLIGHT_NOROOT` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `GCRY_BIRTH_GRACE_NOROOT` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `GCRY_STACK_BOUNDS_NOGROW` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `GCRY_DISABLE_SCRUB_FIBERS` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `GCRY_DISABLE_AUTO_LAYOUTS` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| *(none)* | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## Two red arms landed

Both verified, neither needing a line of collector code:

    ! GCRY_DISABLE_GREG_ROOTS=1   $(BIN)/greg_roots         # make greg-roots
    ! GCRY_DISABLE_STATIC_ROOTS=1 $(BIN)/static_bss_roots    # make static-bss-roots

`greg-roots` is the one worth having: the knob is *targeted* — it reddens that
gate and nothing else — and the gate it reddens covers the v0.19.0 defect shape
on two platforms, where rot means live objects are swept in silence. Census
moves 20 → 21; `static-bss-roots` was already counted, because its harness forks
a child under `GCRY_STATIC_BSS_CAP`.

And it repeats yesterday's lesson exactly. Under `GCRY_DISABLE_GREG_ROOTS=1`:

    register candidates from suspended threads: 0
    victim 0x7fb6c39201e0: live?=true intact=true

**The victim survives the break.** The conservative stack scan reaches it. What
goes red is the counter. A survival-only assertion would have stayed green here —
four for four now.

## What I did not wire, and why

- **`GCRY_DISABLE_SP_CLAMP` hangs** `greg_roots` and `scheduler_roots` rather
  than failing them (124 = the 90 s timeout). A red arm that hangs costs a job
  timeout and reports nothing, which is the failure mode CI job timeouts were
  added for. It needs a bounded harness before it can be an arm; the hang is
  itself worth knowing — the SP clamp is load-bearing for both harnesses.
- **`GCRY_DISABLE_STATIC_ROOTS` kills five of the seven** root gates (exit 11)
  rather than failing them. On `static_bss_roots` and `mark_audit` it is a clean
  exit 1, so it is wired only to the former. A knob this broad is a gate arm on a
  harness that gates on it and a crash everywhere else.
- **Seven knobs no gate notices**: `GCRY_DEAD_STACK_NOROOT`,
  `GCRY_POOLED_STACK_NOROOT`, `GCRY_MAPS_INFLIGHT_NOROOT`,
  `GCRY_BIRTH_GRACE_NOROOT`, `GCRY_STACK_BOUNDS_NOGROW`,
  `GCRY_DISABLE_SCRUB_FIBERS`, `GCRY_DISABLE_AUTO_LAYOUTS`. Each disables a root
  path and every gate above stays green. That is **not** evidence the knobs are
  no-ops: none of these gates constructs the condition the knob breaks — a dying
  fiber's stack holding the only reference, a pooled stack, an in-flight maps
  range, the birth-grace window, stack-bounds growth past the initial capacity.
  The gap is that the condition has no harness, which is a bigger piece of work
  than a recipe line and is recorded rather than guessed at.

## Method note

The first attempt at these two recipe lines wrote `__omp_shell("…")` into the
Makefile instead of a `!` prefix — a substitution by the tooling used to edit it,
caught because `make` then failed with a shell syntax error rather than silently.
Worth recording next to yesterday's swallowed-exit-status note: both are ways an
arm can stop being an arm without the file looking wrong.
