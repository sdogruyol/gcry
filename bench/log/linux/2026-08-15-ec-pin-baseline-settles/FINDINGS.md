# The pin gate measured from an unsettled baseline, and it cut both ways

**Date:** 2026-08-15 · host: WSL2 x86_64 idle, Crystal 1.22.0-dev ·
`bench/scheduler_roots.cr`

`make scheduler-roots` went red three times on 2026-08-15 — once on aarch64, twice
on Darwin — always in the same arm and never on x86_64:

```
pins on a collection before any Parallel EC: 23
pins on a second such collection:            25
delta: 2
FAIL: the pin count moved by 2 with no Parallel EC in the process —
      the counter is not measuring the Parallel block, so the gate arm proves nothing
```

It reads like a platform difference. It is not.

## Reproduced on x86_64, 1 run in 25

40 runs of `--control` on an idle host, before any change: one came back
`delta: 2`. The other 24 were 0. So the same defect is present everywhere and
merely rarer here — which is why CI's x86_64 jobs almost never showed it while
the two slower runners did.

## It is not a thread appearing

The obvious reading is that a worker of the default `Parallel` context starts
late and brings its own per-thread pins. Measured — pin count and
`/proc/self/status` `Threads:` at every collection, 12 runs:

```
0=25/2t  1=25/2t  2=25/2t  …      ← 11 runs
0=23/2t  1=25/2t  2=25/2t  …      ←  1 run
```

The thread count is flat at **2** through the jump. Whatever the two pins are,
no thread carried them in.

## It is time, not the collection

A 50 ms sleep before the first collection, 10 runs: **25 every time**. So the
count is not something the first collection fails to see and the second one
does — it is the runtime still finishing its own asynchronous boot while the
harness is already measuring.

## Why this was worse than a flaky arm

The same first-collection read is the baseline for **both** arms:

```crystal
GC.collect
before = HEAP.ec_root_pins        # 23 instead of 25, 1 run in 25
…
delta = after.to_i64 - before.to_i64
```

`--control` asserts `delta == 0` and went red. The hold arm asserts
`delta >= expected` — and a baseline that is 2 low makes the delta **2 high**,
so the gate quietly graded itself on a curve. The failing Darwin run is the
example: `before: 23`, `delta 49` against 45 expected. Settled, it was 47.

So the arm that went red and the arm that stayed green were wrong in opposite
directions, from one line.

## The fix

`settled_pins` collects until two consecutive readings agree (bounded at 8), and
both arms baseline off that instead of off the first collection. After it:

| | before | after |
|---|---|---|
| `--control` non-zero delta | 1 in 25 | **0 in 40** |
| hold baseline | 23 or 25 | **25**, every run |
| hold delta | 49–53 (inflated when 23) | 49–53, honest |
| `make scheduler-roots` | red 3× in CI today | **8/8** local |

No threshold was changed. The gate is the same claim, measured after the number
it depends on has stopped moving.
