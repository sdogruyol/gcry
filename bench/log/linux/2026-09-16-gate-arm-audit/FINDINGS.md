# Can the gates still fail? A census, and three broken on purpose

**Date:** 2026-09-16 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `541e54b` · Crystal 1.21.0 · `bench/gate_arm_census.py`

Every gate here asserts something. This audit asks the narrower question that has
now bitten three times: **can it still come out red?**

- `make page-release-corruption` and `make live-graph-audit` had rotted into
  testing nothing and shipped that way for releases (both fixed in 0.26.0).
- The soak carried an arm recorded as "EC4" for six weeks while running one
  worker (`../2026-09-16-soak-worker-count/`).
- The `--resize` arm added to `make scheduler-roots` earlier today passed on its
  first version because the window it measures was never open
  (`../2026-09-16-ec-shrink-window/`).

In all three the assertion ran. What was missing was its ability to fail.

## Census

`bench/gate_arm_census.py`, so the numbers below can be re-derived rather than
believed:

    harness-driven gates:              84
    red direction constructed per run: 20
    red direction established by hand: 64
    prose claims of a hand break:      19 (nothing re-checks these)

> **Correction, later the same day.** Those two middle numbers were the tool's
> first two criteria only — a recipe `!`/`grep -q`, or a harness that forks a
> child. They missed a third shape that is just as much a per-run red arm: the
> recipe running the harness again under a knob or flag that restores the
> pre-fix behaviour, with the harness judging that arm. `make dead-stack-root`,
> added hours later, was counted "by hand" by the narrow criteria despite three
> of its four arms *requiring* the victim to die — which is how the gap was
> found. With the criteria widened the same tree reads **30 per run / 55 by
> hand** of 85. Nothing in the tree changed to move it; the definition did.
> `../2026-09-16-orphan-break-knobs/` and this file's own argument stand — what
> does not stand is "20".

A gate's red direction is *constructed per run* when the gate itself executes
something that has to fail — the recipe prefixes a command with `!` or asserts on
its output with `grep -q` (`tls-roots`, `interior-only-buffer`,
`unaligned-only-buffer`, `ec-queue-audit`, `ignored-knob-warnings`,
`kernels-broken`), or the harness forks a child under a breaking knob and judges
it (`stw-watchdog`, `segv-report`, `page-release-corruption`,
`static-bss-roots`, `thread-block-audit`, …). `stw_watchdog.cr` is the model: three
arms — armed+stalled must print and name the phase, armed+not-stalled must stay
silent, stalled+unarmed must stay silent — all three built by forking children.

For the other 64 the red direction was established once, by hand, by whoever
wrote the gate, and `ROADMAP.md` records it in prose: *"broken on purpose and
observed red"*, 19 times. Nothing re-checks those 19.

**The classification is mechanical and approximate in both directions.** A
harness that breaks its subject in-process without forking reads as "by hand"
when it is not (`counter-loss --inject`, `thread-birth-root --noroot`). A
`--control` arm is correctly *not* counted: a control that must **pass** shows the
harness is not what keeps the subject alive — it is not evidence the gate can
fail. `bench/scheduler_roots.cr`'s own header has said exactly this about its
end-to-end arm since 2026-08-15.

## Three sampled by actually breaking the collector

Not by reading. Each break was applied to the collector, the gate was run, and
the tree was reverted.

| gate | break applied | result |
|---|---|---|
| `greg-roots` | `Platform.each_thread_greg` stubbed to yield nothing — the Darwin v0.19.0 shape | **red**, both arms, exit 1 |
| `ivar-layout-roots` | `has_inner_pointers?` dropped from `Layout.register`'s fallback — the pre-fix behaviour | **red**, hold and `--proc` exit 1, `--control` stays 0 |
| `scheduler-roots --resize` | the `ec.@schedulers` pin loop removed | **red**, `0 named pins dropped where 24 are derivable`, exit 1 |

All three discriminate. The census number is about *re-verification*, not about
the gates being hollow — where sampled, they are not.

## What the breaks taught, which is the reusable part

**A survival assertion does not discriminate. A counter does.** In every one of
the three, the object under test *survived the break*:

- `greg-roots` with the register scan stubbed: `victim … live?=true intact=true`.
  The conservative stack scan reached the victim anyway. What went red was
  `register candidates from suspended threads: 0`.
- `scheduler-roots --resize`: the removed schedulers and their queues survive
  even with `thread.@scheduler`'s pin deleted, on the `Thread` body scan and the
  worker's stack. What went red was the pin quantity.
- `ivar-layout-roots` is the exception that proves the rule: it *does* catch the
  sweep — because it asserts on the layout entry's offset list first, and reports
  the sweep second.

So a gate whose only assertion is "the object survived" is measuring the union of
every root path, conservative ones included, and cannot attribute. This is the
same lesson the pin block itself was built on (Kemal EC4 SEGV at `…0008`), and it
is now three-for-three.

## One hazard checked and not found

Piping a gate into `tail`/`grep` discards its exit status — which is how the
first measurement in this audit read `exit=0` for a gate that had in fact exited
1. Committed recipes and scripts were checked for the same mistake:

- `ignored-knob-warnings` pipes three commands into `grep -q`, but that *is* the
  assertion (the gate is about the warning text), and the `if` tests grep.
- `bench/run_all.sh` pipes two builds into `tail -1` and sets `pipefail`.
- No other recipe or script pipes a gate's output onward.

`bench/gate_arm_census.py` restores `SIG_DFL` for `SIGPIPE` so that reading it
through `head` does not traceback.

## What this does not claim

No gate was found hollow. The finding is that **64 of 84 gates rest on a hand
break recorded in prose**, and the repo has three instances of that arrangement
decaying without anyone noticing. The fix per gate is the `tls-roots` shape — a
research knob that restores the pre-fix behaviour plus a recipe arm that requires
it to fail — which is 64 separate pieces of work and is recorded in `ROADMAP.md`
rather than started here.
