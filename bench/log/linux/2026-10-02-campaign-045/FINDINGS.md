# Stress campaign-045: `pattern_fuzz` only, `--debug` build (2026-10-01/02)

`a406744`, five lanes for eight hours, alternating the diagnostic
environment and the plain one. It was run to catch the Stride-phase stall
with gdb's `info locals`, so the binary was built with `--debug`.

**1 285 runs, 38.4 lane-hours, 0 failures, 1 timeout.**

| lane | runs | failed | timed out |
|---|---:|---:|---:|
| `pattern_fuzz+diag` | 642 | 0 | 1 |
| `pattern_fuzz` | 643 | 0 | 0 |

The timeout is seed 20109. Its locals showed `unlink_chunk` at step 13 981
of a 58 262 limit with the trim's detach loop at its first step: not a cycle,
but the quadratic large free over an index retention had grown to about
29 000 chunks. Diagnosis and the harness change that followed:
`../2026-10-01-large-free-quadratic/`. The binary here predates that change.
