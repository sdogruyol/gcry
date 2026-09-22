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

## The first profile, and the accounting gap it exposed

Run `35739434001`, `test (aarch64 native)`:

```
 66  timeout 600 make stw-epoch
 21  timeout 300 make stw-ack-window
 18  crystal spec --release spec/kernels_spec.cr
 18  crystal build --release spec/kernels_spec.cr
 13  crystal spec
 12  env GCRY_SEGV_REPORT=1 timeout 600 make large-cache-race
  9  crystal spec -Dgc_none -Dgcry_block_headers process_spec
  8  timeout 300 make ec-queue-audit
  7  timeout 300 make thread-census-names
28 commands, 239 s accounted for
```

`stw-epoch` is the single largest item at 66 s, and no gate is anywhere
near its `timeout 300` / `600` bound.

But the step runs ~384 s, so **145 s was unaccounted** — the wrapper
covered every line that starts with a command and missed exactly the
ones that do not: `sudo apt-get update` / `install -y qemu-user`, the
`for trial in 1 2 3; do crystal spec -Dgc_none process_spec; done` loop
(three full process-spec runs, likely the biggest single cost in the
job), and the `! GCRY_DISABLE_SP_CLAMP=1 ./bin/stw_sp_clamp` red arm.

All four are timed now — `t` inside the loop body, and `! t env …` for
the negated one, both verified not to kill the shell under `set -e`. A
profile that accounts for 62% of its step is a profile that can hide the
growth it exists to find.

## Second profile: 34 commands, 297 s of a 437 s step

Run `35772773739`, with the loop body, the apt-get pair and the negated
arm now timed:

```
 22  timeout 300 make stw-ack-window
 20  crystal build --release spec/kernels_spec.cr
 19  crystal spec --release spec/kernels_spec.cr
 15  env GCRY_SEGV_REPORT=1 timeout 600 make large-cache-race
 15  crystal spec
 12  sudo apt-get update
 11  crystal spec -Dgc_none process_spec      (trial 1 of 3)
 10  crystal spec -Dgc_none -Dgcry_block_headers process_spec
  9  timeout 300 make ec-queue-audit
34 commands, 297 s accounted for
```

Still 140 s short of the step, and the reason is one line:
`FIND_BLOCK_RACE_RUNS=3 timeout 600 make find-block-race` — a race gate
with three children and a 600 s bound, untimed because the wrapper's
regex allowed a `GCRY_*` environment prefix and this one is
`FIND_BLOCK_RACE_RUNS`. Wrapped now, and the step's body has no
unwrapped command left (checked by parsing the workflow rather than by
eye, which is how the first two escaped).

Worth noting for the next time this job is trimmed: the three `crystal
spec -Dgc_none process_spec` trials cost 11 + 7 + 7 = 25 s together, and
the two `--release` kernel builds 39 s — the profile's top is
compilation and one race gate, not the collector's gates.
