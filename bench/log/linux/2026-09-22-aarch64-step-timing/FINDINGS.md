# The aarch64 job grew 60% inside one step, where nothing could see it

**Date:** 2026-09-22 · CI, `test (aarch64 native)`

Closing the aarch64 hang item measured the job: 42 consecutive green,
p50 406 s, **max 705 s against a 1200 s bound**, where the item had
recorded max 443 s three days earlier. 41% of headroom left, and the
thing to watch is now the duration rather than the hang.

The x86_64 job's equivalent growth (16 → 33 min in twelve days) could be
attributed: it has 31 steps and they diff. This job is **one step** —
`Unit + process specs + STW SP + fork on aarch64`, 384 s of the 399 s
total in the sample below — and a step is the finest granularity GitHub
reports. So "which part grew" had no answer.

```
  384  Unit + process specs + STW SP + fork on aarch64
   10  Run crystal-lang/install-crystal@v1
    3  Run actions/checkout@v7
```

## What changed

A `t` wrapper around each of the step's 28 commands records its seconds,
and an `EXIT` trap prints the fifteen slowest plus the total accounted
for. Two details that are the whole value:

- **The trap, not a trailer.** A step that dies at command nine would
  otherwise lose the eight before it, and the run that fails is the one
  whose profile is worth having.
- **`"$@" || r=$?`, not `"$@"; r=$?`.** Under `set -e` the second form
  kills the shell inside the function before the timing is written, so
  the *failing* command — the interesting one — is the only one missing.
  Verified both ways locally: with the fix a failing command is recorded
  with its duration, the trap still prints, and the step still exits 1.
- `t env VAR=1 cmd` for the two commands with an environment prefix:
  `t VAR=1 cmd` would exec `VAR=1` as a program.

Costs one `date` per command. The next growth arrives attributed.
