# Windows x86_64 gates: one 30-minute cancel inside `find-block-race`

Master run 37174417022 on `c25cae7` (a findings-only commit; the product was
`765fb6a`, whose run passed the same job in 13.2 min): `test (windows x86_64,
gates)` was cancelled at its 30-minute limit. The job's recent runs took
13.2–17.8 min.

The log stops in `make find-block-race`, after the restored-read control's
`live crashed 1 of 1` at 03:40:18; nothing more was printed until the cancel
at 04:04:48. In the passing run the next line, `realloc crashed 1 of 1`, came
0.6 s after `live`.

## What it is not

- **A slow control.** `run_arm` counts a child that outlives
  `BoundedChild`'s 120 s deadline as crashed, so the control loop stops at
  its first hang; one try is bounded at ~120 s plus the kill. 24 minutes of
  silence is the parent not returning, not tries piling up.
- **The idle collector firing while the parent waits.** The Windows idle
  collector went default-on the day before, and a parent polling a slow child
  goes two minutes without allocating. `idle_wait.cr` reproduces that shape —
  a gcry parent, one collection to start the idle thread, then a 150 s
  poll-and-sleep wait on a child that outlives it — on windows-latest
  (run 37176576367): the idle collection fired during the wait
  (`collections=1 → 2`) and the parent finished at its deadline; with
  `GCRY_IDLE_RELEASE_MS=0` and with a 5 s idle period, the same.

## Open

One hang of the `find_block_race` parent, on Windows x86_64, after a
deliberately crashed child, with nothing captured: `BoundedChild` only
captures a stalled *child*, and the job has no debugger. A repeat would want
the parent's stacks.

## Rate (2026-10-05)

Probe `probe-fbr-windows` on `ea89c48`, windows-latest: the gate's binary
(`FIND_BLOCK_RACE_RUNS=3`) run 40 times back to back, each watched for 270 s
— **0 hung, 0 failed**; durations 8 s minimum, 16 s median, 124 s maximum (a
control child reaching `BoundedChild`'s 120 s deadline, as designed). One in
one CI run, none in 40 here: rare enough that only the CI job will see the
next one. The runner has `cdb.exe`
(`C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\`), and
`cdb -p <pid> -c "~*kb 25;qd"` on the parent is what a repeat should run;
`fbr.sh` beside this file is the probe script.
