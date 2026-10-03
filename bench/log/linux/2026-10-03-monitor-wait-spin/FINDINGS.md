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
