# The 2026-08-10 nightly: two red jobs, two different bugs, neither re-tested

**Date:** 2026-08-13 · host: WSL2 x86_64, 16 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none`, default execution context · tip @ `c0ba2fa`

The weekly scheduled run of 2026-08-10 (`31365039411`, HEAD `d36effe`) failed in
two places. Both were referenced afterwards as "the nightly soak SEGV", as if
they were one event. They are not, and only one of them is still open.

## 1. The six-hour `test` job was the STW hang, not a mystery

Both `test` jobs — `crystal 1.21.0` and `crystal latest` — ran **6h00m14s** and
**6h00m15s** and were then cancelled. That is not a repo timeout; there were no
`timeout-minutes` in the workflow at all. It is GitHub's ceiling for a
hosted job.

The last line each job printed:

```
STW-MT workers=4 iterations=50 seed=10001
```

and the process the runner had to kill on the way out:

```
Terminate orphan process: pid (4850) (stw_mt_property_test)
```

That is the exact shape of the bug fixed later the same day in `8f2cdad`: the
collector called `pthread_getattr_np` on threads it had already suspended, which
waits on a lock a frozen thread can hold. It was isolated to **non-main threads**
(9 of 100, against 0 of 100 for the main thread) — and `workers=4` is the
non-main arm. The run's HEAD `d36effe` predates the fix by about five hours.

Local re-run of that exact arm on tip, watchdog armed: **PASS in 1.5 s**, no
watchdog line. `make stw-startup-hang` on tip: **0 hangs in 150 starts**.

**Closed.** What it cost, though, was six hours of runner time twice over, in
silence — which is what the next two sections are about.

## 2. The soak has never once completed in CI, and could not have

`soak (24h)` asked for `--duration=86400` on a runner GitHub cancels at 6 h.
Both scheduled runs that ever reached it:

| run | date | soak outcome |
|-----|------|--------------|
| `30801415628` | 2026-08-03 | **cancelled at 6h00m14s** — the ceiling |
| `31365039411` | 2026-08-10 | **SEGV at 1h24m** |

So the gate has produced exactly one signal in its life, and that signal was a
crash. A gate that cannot pass is not a gate. Worse, the crashing run threw its
own evidence away: `Upload telemetry` had no `if: always()`, so it was skipped,
and the hours of heap/pause/RSS history leading up to the SEGV are gone.

Both are fixed here: the CI soak is now 5 h (the 24 h number stays local, via
`make soak`), the job is dispatchable rather than Monday-only, and the telemetry
upload runs on failure too.

## 3. The SEGV itself

```
Invalid memory access (signal 11) at address 0x7f1700000149
[0x7f171ea45330] ?? in /lib/x86_64-linux-gnu/libc.so.6
[0x561392710f92] *Fiber::ExecutionContext::Parallel::Scheduler#quick_dequeue?:(Fiber | Nil) +194
[0x5613926ad956] *Fiber::suspend:Nil +6
[0x56139270ec53] *Crystal::EventLoop::Polling+ +483
[0x5613925c653f] *sleep<Time::Span>:Nil +79
[0x5613926adce5] *Fiber#run:Nil +117
[0x0] ???
```
(job `93381494764`, 2026-08-10T08:38:57Z, 1h24m into the run)

`0x7f1700000149` is a heap address with its low bytes overwritten — the
signature of a slot that was freed and reused while something still pointed at
it, read back through the scheduler's run queue.

The standing candidate mechanism is the one found the next day: the EC Monitor
ran **inside** the stopped world (`bench/log/linux/2026-08-11-sysmon-runs-during-stw/`),
mutating scheduler ownership and munmapping fiber stacks while the collector
believed every thread was frozen. `Gcry::MonitorGate` (`22db2db`) closed that,
five hours after this run. Whether it was *this* crash was left open, because
the crash never reproduced.

## 4. Was it the Monitor? Measured: almost certainly not

`GCRY_MONITOR_GATE=0` restores the pre-fix behaviour exactly, and
`GCRY_STW_TEST_STALL_MS` holds the world stopped at the entry to the
thread-stacks phase on **every** collection. Together they turn "wait 24 h and
hope" into an arm that can be run in an hour. Four soaks, this host, concurrent:

| arm | stall | elapsed | collections | pause p50 | world stopped | `collect_stacks` chances | overlaps | result |
|-----|------:|--------:|------------:|----------:|--------------:|------------------------:|---------:|--------|
| `gate-off-50` | 50 ms | 3601 s | 3404 | 65.1 ms | 6.2% | 720 | **44** | PASS |
| `gate-off-200` | 200 ms | 3604 s | 2995 | 201.4 ms | 16.7% | 720 | **121** | PASS |
| `gate-off-1000` | 1000 ms | 2702 s | 1347 | 1014.4 ms | 50.6% | 540 | **273** | PASS |
| `gate-on-50` (tip) | 50 ms | 3600 s | 3411 | 65.6 ms | 6.2% | 720 | 3419 held off | PASS |

"Overlaps" = `COLLECT_STACKS_EVERY` is 5 s, so the number of chances is
`elapsed / 5`, and the fraction of them landing inside a stop is the fraction of
wall time the world was stopped. Each arm's `config:` line and final counters are
in its telemetry, so the arm labels are checked rather than assumed:
`gate-off-*` all report `monitor_blocks=0`, `gate-on-50` reports 3419.

**438 overlaps across the three control arms, no crash, no stderr byte.**

For scale: the soak's natural pause is **1.27 ms** at 1 Hz, i.e. the world is
stopped **0.127%** of the time, so the 2026-08-10 CI run had about **1.3**
expected overlaps in the 1h24m before it died. This session ran **~340× that
exposure** to the pre-fix behaviour and produced nothing.

### What this bound does and does not cover

The stall widens *the world being stopped*, and the collector spends the added
time in `nanosleep`. So what is amplified is the Monitor being **active while the
collector holds a stopped-world snapshot** — mutating scheduler ownership,
returning pooled stacks to the OS — which is the mechanism that would corrupt a
scheduler queue. That is the one bounded above.

It does **not** amplify the narrower race of a `munmap` landing while the
collector is actually walking thread stacks. But that one does not need a soak to
rule out, only a measurement: the thread-stacks phase is **30 µs** median (max
95 µs) against a 2.76 ms pause — **1.1% of the stop** — on a 100-parked-fiber,
allocation-churning shape (`phase_probe.cr`; the soak's own pause is smaller
still). A 5 s `collect_stacks` period against a 30 µs window is one expected hit
per **~46 hours** (0.2 chances per second × 3e-5 of wall time in that phase).
The 2026-08-10 run died after 1.4 h.

Both halves point the same way, from opposite directions: by rate, the Monitor
overlap is a poor explanation for that SEGV.

**So the question does not close as "fixed" — it closes as "excluded, to this
rate".** `MonitorGate` remains right on its own terms: the Monitor really did run
inside the stopped world, that really is unsound, and it is now measured to cost
one wait of **263 ns** in 3411 collections (`stw_waits=1`, `stw_wait_max_ns=263`)
— a sharper number than the "zero added pause over 3000 collections" recorded
when it landed. It is simply not the answer to the crash.

**Still open, and now unattributed:** what overwrote a pointer in
`Parallel::Scheduler`'s queue on 2026-08-10.

### Caveats

- WSL2, 16 CPUs, four soaks running concurrently — not the 4-CPU GitHub runner
  the crash happened on. A coincidence tied to core count or to the runner's
  scheduling would not reproduce here.
- Absence over N overlaps bounds a rate; it does not prove a race cannot happen.
  The bound is ~340× the exposure at which CI died, not infinity.
- One host, one day. The 5 h CI soak (§2) is now able to run to completion for
  the first time, and Monday's is the arm that carries both fixes.
