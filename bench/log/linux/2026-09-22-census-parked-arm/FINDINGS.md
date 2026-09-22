# `make thread-census-names` asked a peer thread to be asleep, and once it was not

**Date:** 2026-09-22 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `57c1964` · CI run `35707265944`

Two of the gate's arms ask *where* a task is: the
`task N:comm is parked in syscall S, returning to 0xPC in /path+0xOFF`
line, and the `returns through:` walk above it. Neither planted a parked
task. The planted probe **spins** on purpose — it stands in for a thread
whose runtime is not up — so the subject of both arms was whichever peer
happened to be in a syscall, in practice Crystal's `SYSMON`.

On 2026-09-22 neither was:

```
gcry: thread census — task 7401:thread_census_n is the collector, stopped here to ask
gcry: thread census — task 7402:SYSMON is on-CPU, so it has no syscall frame to report
gcry: thread census — task 7403:census-probe is on-CPU, so it has no syscall frame to report
FAIL: no task was located — the syscall site or the mapping lookup produced nothing
```

A green tree, a red job. Locally the plain arm is **20 of 20**, so the
rate is the runner's and not the gate's — which is exactly the shape that
gets re-run rather than fixed.

## What changed

`--parked`: the same raw pthread, sleeping in 20 ms `nanosleep` calls
instead of spinning, so a task parked in a syscall with a resolvable
return site exists by construction. Both location arms use it; every
other arm is untouched, so the counts they assert are unchanged.

| | |
|---|---|
| `--parked`, located lines, 5 runs | 2, 2, 2, 2, 2 |
| `--parked`, `returns through` into this binary, 5 runs | 2, 2, 2, 2, 2 |
| `--parked`, `census-probe` named | 4 |
| whole gate, 3 runs | 14 `ok` each, exit 0 |
| syscall site broken on purpose | arm red |

20 ms rather than one long sleep, so the join at the end still takes
about that long: a thread parked in a single long sleep would have to be
signalled out of it, and a signal is what the census must not need.
