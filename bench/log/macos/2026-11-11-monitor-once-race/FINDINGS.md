# The Monitor waited in a class variable's `once` at startup (2026-11-11)

PR #57's CI run 42974328030 on `97d866a1` (release 0.40.0), job `test
(darwin native)`: regression 107's unplanted child died before its spec ran.

```
Unhandled exception: Fiber#execution_context cannot be nil (NilAssertionError)
  fiber.cr:77 execution_context <- fiber.cr:263 enqueue <- pointer_linked_list_node.cr:12
  <- crystal/once.cr:32 resume_all <- once.cr:96 <- once.cr:124 __crystal_once
  <- src/gcry/monitor_gate.cr:440 in '__crystal_main'
```

## Mechanism

- **`once` is per flag.** Crystal 1.21.0's `crystal/once.cr` (1.22.2's is
  the same here) keeps one global spin lock and a list of `Operation`s, one
  per initializer in progress; a thread that reads a flag whose initializer
  another fiber is running adds itself to *that* operation's waiters and
  suspends; the runner, when done, `resume_all`s that list. A class variable
  or constant with a call initializer (`@@x = Atomic(Int32).new(0)`, `@@phase
  = PHASE_NONE`, `PAGE_SIZE = begin … end`) goes through it; a literal one
  (`@@x : Int32 = 0`) does not, and has no flag in the binary (`nm`: no
  `…::x:init`).
- **The Monitor exists before gcry's class variables.** `kernel.cr`'s
  top level calls `Fiber::ExecutionContext.init_default_context`, which
  starts SYSMON, inside `__crystal_main` and before the user's requires, so
  gcry's declarations are initialized by the main thread while the Monitor
  runs. Its thread's main fiber has no execution context.
- **On 1.21 waiting kills the program.** In `wait_initializer` the Monitor's
  `Fiber.suspend` raises `Thread#scheduler cannot be nil`, which `every`
  rescues ("BUG: …#every crashed"), leaving its waiter node on the list; the
  main thread's `resume_all` then enqueues that fiber:
  `Fiber#execution_context cannot be nil`, or a segfault on the dead node.
  1.22.2 waits on the thread (`Once::Waiter` with a `Thread`) and survives;
  the Monitor stalls for as long as the initializer runs.

Evidence (Linux, Crystal 1.21.0, `once_waiter_probe.cr`, which wraps
`Crystal::Once.run_initializer`/`wait_initializer` to log the flag as an
`nm` offset and, with `PROBE_DELAY`, holds the main thread 2 ms in every
initializer): with `GCRY_MONITOR_LOOP_TEST=1` at `97d866a1` the Monitor ran
the initializers of `MonitorGate::loop_test_ready`, `site`, `busy`,
`stopped` itself (it got there before the slowed main thread), and in one
of four runs waited (`ec=false`) on `Time::Span::ZERO`, whose initializer
the main thread was running, and the process died with the CI's exception.
Held inside a *gcry* initializer the Monitor reads, it dies the same way
(`production_hold_probe.cr` below, regression 112's control arm).

Which flag the CI's Monitor waited on: the 107 children set
`GCRY_MONITOR_LOOP_TEST`, so the Monitor's loop prologue reads
`@@loop_test_ready` (`:379`) at its birth, racing the main thread's
initialization of it. `:440` (`@@sleep_test_ready`) is never read by the
Monitor with `sleep_test == 0` and `once` is per flag, so the `:440` frame is
[INFERENCE] the debug location of the shared, inlined `__crystal_once` slow
path, not the variable.

Natively on tmac (M2 Pro, Crystal 1.21.0), regression 107 whole, every arm
in a process of its own (`loop.sh`): at `97d866a1` **29 of 2 000 runs** died
with this exception (10 unplanted, 8 control, 11 halves-control children);
at the fix 0 of 2 000.

## Production exposure

Yes, on Crystal 1.21, from before 0.40. With no `GCRY_*` knob the Monitor's
first lazily initialized reads are `MonitorGate`'s `@@site`, `@@busy`,
`@@stopped` (`Atomic(Int32).new`, in the gate since at least v0.36.0), in its
first gated call ~10 ms after it starts. `production_hold_probe.cr` holds
the main thread 50 ms inside one named initializer, no knob, at `97d866a1`
on Linux: inside `@@site`'s 5 of 5 runs died, `@@stopped`'s 2 of 5, `@@busy`'s
0 of 5 (the Monitor reads `@@site` first); on 1.22.2 inside `@@site` 3 of 3
ran to the end. A program hits it when its main thread is in one of those
initializers at the Monitor's first pass: a window of nanoseconds, reachable
on a loaded machine or behind a large prelude, and in a library heap never
(no Monitor wrappers).

What 0.40 added: the loop prologue (`7bfb0358`, `2658369a`) runs gcry code at
the Monitor's *birth*, while the main thread is still in the prelude and
gcry's declarations, and with `GCRY_MONITOR_LOOP_TEST` it read
`@@loop_test_ready` there — the CI's crash, research knobs only. With no knob
the prologue and the `Thread.sleep` wrapper (`32b11119`) read only literal
variables and `Platform.host_page_size`, whose Linux `PAGE_SIZE` is a lazy
constant the event loop's arena initializes before the Monitor exists
(observed: its `const_init` ran before `execution_contexts:init`).
`sleep_test_ready` (`:440`) is read only under `GCRY_MONITOR_SLEEP_TEST`.

Not gcry's: with every initializer held 2 ms the Monitor also waited on
`Time::Span::ZERO` (`every`'s `clamp(Time::Span.zero..)`), the stdlib's own
lazy constant; same death, Crystal 1.21 only.

## Fix

Everything a bare thread reads is literal-initialized: `MonitorGate`'s
`@@stopped`, `@@busy`, `@@site`, `@@loop_test_ready`, `@@sleep_test_ready`;
`IdleRelease`'s `@@parked_sp`, `@@hold_masked`, `@@birth_spins`,
`@@birth_released`; `StwWatchdog`'s `@@phase`, `@@suspend_step`. The atomics
go through `Gcry::StaticAtomic` (sequentially consistent `Atomic::Ops` on
`pointerof`, as `Atomic(T)`'s defaults). The Monitor's and the idle thread's
scrubs take the page from `Roots.runtime_page_size` (uninitialized storage,
filled on first use) instead of `Platform.host_page_size`.

## Regression 112

`MonitorOnceTest` (`GCRY_MONITOR_ONCE_TEST`) holds the main thread inside a
class variable's initializer, in a file required before every gcry file that
declares class variables, until the Monitor has finished three gated calls
or 3 s pass. Fixed arm: the Monitor finishes them (prologue, sleeps, gated
work all ran meanwhile). Control arm: the Monitor reads the held variable,
an `Atomic(Int32).new` as the gate's were: on 1.21 the child dies in `once`,
on 1.22.2 the Monitor finishes 1 call and stalls for the hold. A third
example runs `nm` on the spec binary and fails on any `:init`/`:const_init`
flag in `MonitorGate`, `IdleRelease`, `StwWatchdog`, `StaticAtomic`,
`Clock`, `Roots`, `RawOut`, and of `Platform` the low-water probe's state
(`pagemap_*`, `page_query_errors`, `resident_*` and their constants), the
one `Platform` code those threads run (it sees `MonitorOnceTest::held:init`,
so the scan reads flags). That example is the regression: on `97d866a1` it
lists 11 flags (the gate's five, the idle thread's four, the watchdog's two).
The process arms show the mechanism only; the fixed arm would pass on the
old code too, since a main thread held before the gate's declarations
leaves the Monitor to run their initializers itself, and the crash needs
main inside the very one the Monitor reads (`production_hold_probe.cr`).

Specs 76 and 77 hook the Monitor with state of their own; it was
`Atomic.new` too, and is literal-initialized through `StaticAtomic` since
`once-race2-040`. Loops there (each binary whole, 100 runs): 76, 77 and 112
on Linux x86_64 with 1.21.0 and 1.22.2, and on tmac with 1.21.0 and 1.22.1,
100/100 each.

## Loops at the fix (`44b75704`)

Whole spec binaries, every arm in a process of its own, 200 runs each:

| where | Crystal | 107 | 111 | 112 |
|---|---|---|---|---|
| Linux x86_64, local | 1.21.0 | 200/200 | 200/200 | 200/200 |
| Linux x86_64, local | 1.22.2 | | | 200/200 |
| tmac, M2 Pro | 1.21.0 | 200/200 (and 2 000/2 000) | 200/200 | 200/200 |
| CI run 42982589471: macos-latest, macos-15-intel, ubuntu-latest, ubuntu-24.04-arm | 1.21.0, 1.22.2 | 200/200 each | 200/200 each | 200/200 each |

`ci-probe-42982589471.txt` has the 24 CI lines.

## Keep rule

What the fix changes on the default path is the gate's `close`/`open` (once
per stop), the idle thread's park and the watchdog's phase stores: the same
sequentially consistent loads and stores, without the `once` flag check in
front. `perf-ab.yml` 42982736692: `44b75704` against `v0.39.0`, five
runners, nine benches, 15 reps, Boehm, pads `p16 p64 bp16 bp64`; `keep.py`
(`../../linux/2026-11-01-0.40-keep-rule/`): 45 rows, 32 ok, 12 placement,
**1 flagged**: `macos-15-intel` JsonParseSerializable, time +3.9% [+0.9,
+10.3], var-code 1.491–1.559 against base-code 1.437–1.471
(`keep/keep-42982736692.txt`). Followed on that runner, 21 reps, three JSON
rows, four pads, as parked-seed-2 did:

- 42992047056, against `v0.39.0`: all three rows **ok**; JsonParseSerializable
  var 1.638, base 1.629 (`keep/keep-42992047056.txt`).
- 42992093588, against the release tip `97d866a1` itself: all three rows
  **ok**; JsonParseSerializable var 2.399, base 2.351, base-code
  2.346–2.445 (`keep/keep-42992093588.txt`).

No row unexcused.
