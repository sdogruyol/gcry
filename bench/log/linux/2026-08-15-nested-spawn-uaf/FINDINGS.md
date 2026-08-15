# A use-after-free in fiber creation, and it reproduces in seconds

**Date:** 2026-08-15 · host: WSL2 x86_64 **idle**, Crystal 1.22.0-dev

The 2026-08-10 soak SEGV took **1h24m** to arrive, once. That rate is the whole
reason ROADMAP carries "make the soak reproducible enough to bisect": a candidate
fix and a quiet run are the same observation at one crash per five hours.

There is now a use-after-free of the same family that reproduces in **seconds**.

## It was not found by looking for it

`make ec-queue-audit` went red three times today — aarch64 at 06:01, Darwin at
12:58, x86_64 at 18:51. It reads like a flaky gate, and the gate does plant
corruption on purpose, so the obvious reading was that its own manufactured
value was coming home.

Two things said otherwise.

**Where the output stops.** Every crash cut off after `audit: on/off` and before
`slots walked over 8 collections` — inside arm 1's churn, which runs *before* the
harness plants anything.

**What the crash said.** `GCRY_POISON_FREED=1` and `GCRY_SEGV_REPORT=1` were
added to that gate earlier the same day, for exactly this:

```
gcry: SIGSEGV at 0x0 — gcry's freed-block poison (GCRY_POISON_FREED) is in the
faulting context. Something followed a pointer read out of a block that had
already been freed: a use-after-free, not a wild pointer
  … Fiber#makecontext<Pointer(Pointer(Void)), Proc(Fiber, Nil)>
  … Fiber#initialize<Nil, Fiber::Stack, Fiber::ExecutionContext::Parallel, …>
```

On 2026-08-10 the same class of crash left `0x7f1700000149` and nothing else, and
three readings of it were argued for a day. This one classified itself.

## Stripped to the churn

`bench/nested_spawn_uaf.cr` is arm 1 alone: a fiber that spawns a fiber and then
yields, 64 of them per round, 8 collections per round, one context.

| build | crashes |
|---|---|
| gcry, `-Dgc_none` | **16 in 25 runs** |
| Boehm, same file | **0 in 25 runs** |

Same program, same compiler, same workload. **The collector is the subject**, not
Crystal's execution context — that control is what makes the rest of this worth
writing down.

## It does not need parallelism

| workers | crashes in 12 runs |
|---|---|
| 1 | 7 |
| 2 | 7 |
| 4 | 5 |

A single-worker context is enough. That rules out a race *between* workers and
leaves the collector's view of a fiber being constructed while a collection runs.
It also makes the defect far cheaper to chase than the soak ever was: no
parallelism to reason about, one mutator, ~1 in 2 runs.

## Rates, for calibration

| where | rate |
|---|---|
| 2026-08-10 soak | 1 crash in 1h24m, once |
| `make ec-queue-audit` | 1 in 300 local runs |
| this reproducer | ~16 in 25 runs, seconds each |

## What is not claimed

That this **is** the 2026-08-10 SEGV. Same family — a block freed while something
still points at it, inside the Parallel scheduler's world — but that crash was in
`quick_dequeue?` on a queue slot, and this one is in `makecontext` on a fiber
under construction. Whether one explains the other is the next question, and it
is now a question that can be asked of a binary that fails in seconds.

## Not a CI gate

Deliberately. It fails most runs, which is the finding; a gate that is always red
gates nothing, and wiring it in would bury every other signal in the job. `make
nested-spawn-uaf` runs it. It becomes the regression test when the defect is
fixed.
