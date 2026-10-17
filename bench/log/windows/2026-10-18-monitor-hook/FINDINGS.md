# Spec 76's Monitor hook on Windows — 2026-10-18

`process_spec/regression/76_monitor_deep_frame_root_spec.cr` holds a block in
a Monitor frame 64 KiB below its birth, from a hook in
`Monitor#increase_parallelism`. On all eight Windows jobs of CI run
39028591028 (e24c0043) the Monitor never reached that hook in 10 s, and 76 was
compiled out on Windows (31bfd814) with "why was not investigated". Two
questions: why the hook was not reached, and whether the Monitor's deep frames
are scanned on Windows and macOS.

## 1. Why the hook was not reached: a library heap's collection left the Monitor gate closed

Not Windows' Monitor, not the hook. In a fresh process the Monitor runs its
loop on Windows as everywhere, each of its three calls once per pass, and the
probe's hook in `increase_parallelism` is reached; 76 alone passed on windows
x64 before the fix below too (39058010270):

| platform | Monitor passes in the probe's first 1 s | 76 alone |
|---|---|---|
| windows x64 (39058010270, 39059273954) | 69-75 | pass |
| windows arm64 (39059273954) | 63 | pass |
| macOS arm64 (three runs) | 21-36 | pass |
| macOS x86_64 (three runs) | 22-65 | pass |
| linux x86_64 (local, `runs/linux-probe.txt`) | 96-97 | pass |

Windows' `Thread.sleep` is `Sleep(ms)`, at the timer's ~15.6 ms granularity
[INFERENCE: why fewer than Linux's 100 per second]; it is not a stall.

In the whole process suite it did not. The probe
(`scripts/monitor_probe_spec.cr`) waits after every example for the Monitor to
start two more passes of its loop, and on windows-latest without the fix
(`runs/ci-39058010270-windows-x64.txt`):

    MONPROBE stalled after example #154 'agrees with a walk of the chunks through allocation, frees, release and revival':
      transfer=2297/2296 ... gate(enabled=true stopped=1 busy=0 site=transfer_schedulers_blocked_on_syscall ...)
      SYSMON prev_suspend_count=0 ... pc ZwDelayExecution
        nanosleep  src/gcry/platform/windows_os.cr:274
        wait_for_open  src/gcry/monitor_gate.cr:235
        enter  src/gcry/monitor_gate.cr:208
        transfer_schedulers_blocked_on_syscall  src/gcry/monitor_gate.cr
        run_loop  src/fiber/execution_context/monitor.cr:42
    MONPROBE running again after example #155 'unlinks a deep large chunk by its back-link'
    MONPROBE stalled after example #156 'with a thread freeing what it allocated on the hit path': ... stopped=1 busy=0
    MONPROBE before 76 (example #161): ... last_transfer_ms_ago=5133 ... stopped=1
    MONPROBE 76 never reached: ... last_transfer_ms_ago=15134 ... stopped=1

The Monitor was in `MonitorGate.enter` at the top of its pass, sleeping in
`wait_for_open`, with the gate closed (`stopped=1`) while no stop was in
progress: the probe's own thread kept running and printing through those
15 s, and `busy=0`. Its suspend count was 0: not a `SuspendThread` left
unmatched. #154 is regression/70, #156 regression/72: both collect a
`Gcry::Heap.new`. #155 (regression/71) collects the process heap, which
opened the gate again.

The mechanism (`src/gcry/collect_stw.cr`, before e5316086):

- `stop_world_quiescing_roots` — every collection's way into a stop, library
  heaps included — called `MonitorGate.close`;
- `stop_world` returns at once when `@stop_the_world` is false, which it is
  for every library heap;
- `MonitorGate.open` is in `start_world`, which returns at once when
  `@world_stopped` is false.

So a library collection closed the process-wide gate and nothing opened it
until the process heap's next collection. Until then the Monitor did none of
its work: no scheduler blocked on a syscall handed to another thread, no
parallel context grown, no stack pool collected. Every platform has this; it
is not Windows-specific.

Why only Windows failed: order. `ci/windows.ps1` and `ci/crystal-spec.sh` (the
Windows gates job) build the process specs from a sorted list — 70, 71, 72,
73, 75, 76 — so 72's library collection is the last thing to touch the gate
before 76: 73 is Unix-only and 75 collects only in child processes.
`crystal spec` takes `Dir["process_spec/**/*_spec.cr"]` unsorted (directory
order). On the local Linux host that order is `72` at index 11, `70` at 49,
`71` at 53, `76` at 55 (`runs/linux-probe.txt`): 71's process collection
opens the gate right before 76. macOS ran 76 as example #70 of 169
(39059273954). [INFERENCE] the GitHub Linux runners' order also had a
process collection between the last library one and 76; not read there.

### The fix

`MonitorGate.close if @stop_the_world && !@monitor_gate_late_close` in
`stop_world_quiescing_roots` (e5316086). A heap that stops nothing has nothing
to shut the Monitor out of; the second close inside `stop_world` was already
behind `return unless @stop_the_world`.

Regression: `process_spec/regression/77_library_collect_monitor_gate_spec.cr`
— collection off, a library heap's `collect`, then the gate must read open
within 100 ms and the Monitor must make two passes within 5 s.

| | gate fix reverted | with the fix |
|---|---|---|
| linux x86_64 (local) | fail, "gate was still closed 100 ms after", 5.1 s | pass, 21 ms |
| windows x64 (39059273954) | fail, same message | pass |
| windows arm64 (39059273954) | fail, same message | pass |
| macOS arm64 / x86_64 (39059273954) | fail, same message | pass |

With the fix the full Windows process suite (`ci/windows.ps1 -Suite specs`,
probe included) ran 166 examples, 0 failures on x64 and arm64, the stall
detector silent, the gate open with the Monitor at 2081 / 1497 passes before
76 (39059273954). macOS: 169 examples, 0 failures, no stall.

## 2. Is the Monitor's deep frame scanned on Windows and macOS?

The defect 76 was written for is the scan of a thread the stop has **no SP**
for: `scan_other_thread_fiber_ec1` then started at the fiber's
`@context.stack_top`, which for the Monitor's never-switched main fiber is its
birth, 64 KiB above the hold. On Linux the Monitor is never signal-suspended,
so it never has one. Windows (`SuspendThread` + `GetThreadContext`,
`platform/windows_stw.cr`) and macOS (`thread_suspend` + `thread_get_state`,
`platform/darwin_stw.cr`) suspend every listed thread but the collector,
Monitor included, and record its SP — unless the SP clamp is off
(`GCRY_DISABLE_SP_CLAMP=1`; Windows' `thread_sp` then answers nil, Darwin does
not record it) or the thread got no capture slot.

`scripts/monitor_probe.cr` holds a block in a Monitor frame 64 KiB deep (as
76 does), records the Monitor's SP from a MarkStart hook with the world
stopped, collects three times, and asks whether the block is still allocated.
"nofix" is the build with `scripts/revert-fix.patch` (the scan from
`stack_top`, as before dab25144).

Each cell is fix / nofix. "regs off" is `heap.disable_greg_roots = true`
(`GCRY_DISABLE_GREG_ROOTS=1`'s switch) on top of the clamp off, run once per
platform (39059947481); the other columns in every run listed.

| platform | Monitor SP at mark | clamp on | clamp off | clamp off, regs off |
|---|---|---|---|---|
| linux x86_64 (local) | 0 (never suspended), fallback scan | KEPT / **LOST** | KEPT / **LOST** | — |
| windows x64 (39058010270, 39059273954, 39059947481) | recorded, 0xa8-0xf8 below `pad`; fallbacks 0 | KEPT / KEPT | KEPT / **LOST** | KEPT / **LOST** |
| windows arm64 (39059273954, 39059947481) | recorded | KEPT / KEPT | KEPT / KEPT | KEPT / **LOST** |
| macOS x86_64 (four runs) | recorded | KEPT / KEPT | KEPT / **LOST** | KEPT / **LOST** |
| macOS arm64 (four runs) | recorded | KEPT / KEPT | KEPT / KEPT | KEPT / **LOST** |

So on Windows and macOS the defaults were not exposed: the scan starts at the
recorded SP, below the hold. With no SP the same scan lost the block on both
x86_64s. On both arm64s it was kept without the fix even with no SP, and lost
once the register roots were off too: a register the stop read held the
block's address (which register was not read). Both platforms read the
registers whatever the clamp says.

Where the defect is reachable there: any stop that has no SP for a running
thread — `GCRY_DISABLE_SP_CLAMP=1` (shown above), or a thread that got no
capture slot (`stw_capture_no_slot`; [INFERENCE] same path, not exercised).

### Spec 76 now

Runs on every platform (f5dbf29d), with a second example that turns the SP
clamp and the register roots off for its duration, so every platform runs
the no-SP scan with only the frame to keep the block. That example is the
probe branch's third one in 39059947481, the same body:

| | scan fix reverted | with it |
|---|---|---|
| linux x86_64 (local, `runs/linux-spec76-*.txt`) | both examples fail (`free` true) | pass |
| windows x64, windows arm64 (39059947481) | second example fails | pass |
| macOS x86_64, macOS arm64 (39059947481) | second example fails | pass |

## Runs

| run | sha (branch) | what |
|---|---|---|
| 39028591028 | e24c0043 | the original failure, all eight Windows jobs (`runs/ci-39028591028-windows-x64-default.txt`) |
| 39057748994 | c7c50ff2 (probe/win-monitor-hook) | probe v1: macOS both; Windows died on a `run.ps1` parse error |
| 39058010270 | 1c7d2cf3 (probe/win-monitor-hook) | probe v2, pre-fix: windows x64 stall trace; macOS repeat; windows arm64 probe did not build (DbgHelp symbolizer is MSVC-only) |
| 39059273954 | 66403f30 (probe/win-monitor-hook) | probe v3, with the gate fix and the clamp-only second example: all four platforms, both reverts, full Windows and macOS process suites |
| 39059947481 | bb61e1b1 (probe/win-monitor-hook) | probe v4: the register-roots-off arm, all four platforms, both reverts |

The probe branch is deleted; its files (v4) are in `scripts/`: copy
`monitor_probe*.cr` to `bench/`, `monitor_probe_spec.cr` to `process_spec/`,
the workflow to `.github/workflows/`, the rest to `probe/`. v3's full-suite
steps are the ones disabled with `if: false` in the workflow, plus
`crystal spec -Dgc_none process_spec` at the end of `run.sh`.
