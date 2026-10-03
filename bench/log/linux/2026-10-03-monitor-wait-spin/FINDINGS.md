# The Monitor spun through every pause

## Found by

A SIGPROF sampler (`sampler.c`, an `LD_PRELOAD` library: `ITIMER_PROF`,
interrupted PC per sample, `/proc/self/maps` at exit; `report.py`
symbolises with `llvm-symbolizer`). This host has no perf
(`perf_event_paranoid=4`) and callgrind cannot run the process GC (the program
dies at startup with a stack-overflow report), so this was the first
in-process profile of crystal-metric's Primes.

```
SAMPLER_OUT=/tmp/s.txt SAMPLER_US=500 LD_PRELOAD=./libsampler.so ./bin Primes
python3 report.py /tmp/s.txt ./bin 30
```

`samples-primes-before.txt`: **34% of all CPU samples on one PC**,

```
__crystal_once                      crystal/once.cr:124
~Gcry::MonitorGate::stopped:read    gcry/monitor_gate.cr:30
enter                               gcry/monitor_gate.cr:167
transfer_schedulers_blocked_on_syscall
Fiber::ExecutionContext::Monitor#run_loop
```

The Monitor (SYSMON) is not signal-suspended by the stop. It waits for the
world to restart in `MonitorGate.enter`, and its loop runs about every 10 ms,
so it arrives in nearly every pause longer than that. The wait was
`while @@stopped.get != 0; Intrinsics.pause; end`, for the whole pause.

## Cost

`/usr/bin/time`, crystal-metric built with `-Dgc_none --release`, Linux x64,
2 runs per arm:

| bench | arm | wall | user | sys |
|---|---|---:|---:|---:|
| Primes | spin | 2.72 / 2.71 s | 4.13 / 4.16 s | 0.16 / 0.16 s |
| Primes | fix | 2.65 / 2.66 s | 2.55 / 2.55 s | 0.15 / 0.19 s |
| JsonParsePure | spin | 2.95 / 2.93 s | 4.28 / 4.26 s | 0.21 / 0.21 s |
| JsonParsePure | fix | 2.95 / 2.85 s | 2.76 / 2.65 s | 0.23 / 0.27 s |

User CPU −38% on both; wall time unchanged here because the host has spare
cores. With none spare, the spinning Monitor competes with the collector
thread for the pause's whole length.

## Fix

`MonitorGate.wait_for_open`: 1 000 `pause` polls, then `nanosleep` 100 µs
between polls (the pattern `parallel_mark.cr`'s idle helpers use, and for the
same reason: no condvar on Windows' SRWLOCK layer). The Monitor's period is
~10 ms, so up to ~100 µs of lateness after the world restarts costs it nothing
(on Windows the sleep rounds up to `Sleep(1)`, ~1–16 ms, still within its
period). The handshake is unchanged: `busy` is cleared before the wait, and
the register spill stays in `enter`'s frame across the wait.

`samples-primes-after.txt`: the Monitor is gone from the profile; the top
entries are the mark (`scan_object`, `find_block_with_chunk`,
`chunk_containing_unlocked`, `Layout.entry_for`) and the benchmark itself.

## Gate

`process_spec/regression/10_monitor_wait_cpu_spec.cr`: a 1.5 M-node live list,
back-to-back `GC.collect` for 1.5 s, process CPU (`Process.times`, all
threads) over wall must stay below 1.4. The pause runs one thread, so the
ratio is ~1 when the Monitor sleeps and ~2 when it spins.

| arm | build | ratio |
|---|---|---:|
| fix | debug | 1.03–1.05 (3 runs) |
| spin (`monitor_gate.cr` from `c24666b`) | debug | 1.73, 1.97 |
| spin | `--release` | 1.96 |

The spec walks the list after the loop; without that, the release build drops
`head`, every pause is a few µs, and the check passes vacuously (43 732
collections in 1.5 s).

The list is built and walked in `@[NoInline]` helpers with its head held only
in an `Array` that the example clears and collects before it ends. The first
version kept `head` in the example's frame; the list then died under the next
example in file order, `1_live_objects_dormant_spec`, which read a drift of
−73 336 objects and failed 8 of 8 in a single-binary build of the suite. With
the isolation: 10 of 10 full-suite runs green, 8 single-binary and 2
`crystal spec`; red arm 1.92.

## What it exposed on aarch64: the master's termination poll

The next master run timed out `make parallel-mark-termination` on native
aarch64 (ubuntu-24.04-arm, 4 vCPU) twice in a row, at 600 s; the gate had taken
36–143 s there over the previous ten runs. Bisected on throwaway branches, each
running the gate's binary six times with a gdb dump at 240 s:

| tree | per-run seconds |
|---|---|
| `c24666b` (before this change) | 30, 45, 25, 55, 70, 75 |
| `a8b1dbb` (this change only) | 412, 291, 251, 160, 140, 366 |
| `20e9060` (+ the layout inline) | 180, 155, 40, 296, 146, 210 |
| `56c609a` + the fix below | **10, 10, 10, 10, 10, 10** |

Not a deadlock (`aarch64-pmt-stall-gdb.txt`): the child had used 959 s of CPU
in 240 s, the four markers all running, the master in `mark_drain_finished?`
on `@mark_lock` and the workers in `pop_mark_batch`. With the Monitor spinning,
one of the four cores was its for every stop; sleeping, it gave that core to
the markers, and the gate's narrow graph (64 chains × 400 nodes) is all
contention. The master's termination check took `@mark_lock` on every empty
poll, even while workers held batches and the answer could only be no — the
pattern the idle workers' unlocked peek removed on 2026-10-01, still present
on the master's side. Each take is a write to the lock's line, against workers
flushing children through the same lock.

The fix is that peek for the master: an unlocked read of `@mark_workers_busy`
and of the stack's size answers "not yet" without the lock; only a possible
"done" is decided under it, from one critical section as before. The research
arm (`--unlocked` in the gate) still loses a live object on its first
collection (`aarch64-pmt-fix.txt`). Locally, x86-64: the gate, `make
parallel-mark-stress` and `parallel-mark-process` pass.
