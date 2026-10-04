# `parallel-dormant`: a parked fiber kept 23 MB live once

CI run 37228431698 (`a1d0833`, a findings-only commit), job 111512833354,
`test (x86_64, crystal 1.21.0)`, step "Parallel dormant opt-in", arm
`GCRY_PARALLEL_DORMANT_ALL=1 bin/parallel_dormant --ordinary --expect-dormant`:

```
RSS peak 72 MB, after collect 57 MB; empty chunks 21 MB, dormant 0 MB
seeded by stack 2 KiB, parked 2969 KiB, thread 3 KiB, static 2 KiB
the collects: 7 major, 0 minor; ...
warm budget / threshold, MB: 42/42 -> 28/28 (live 23) -> ... -> 26/26 (live 23)
FAIL: no empty chunk went dormant (21 MB of them kept mapped) — the opt-in is inert
```

The arm before it in the same job (`GCRY_PARALLEL_DORMANT=1`) dropped the
live set to 0 and put 36 MB dormant. In the failing arm 23 MB stayed live
through seven majors, and the first-mark attribution names the root: 2 969 KiB
seeded from a **parked fiber's stack**, against 0 KiB when it passes. A stale
word on a parked stack held the structure the benchmark had dropped, so no
chunk emptied and there was nothing to make dormant — the opt-in was not
inert, it had no input.

Locally on `a1d0833`, the same arm 12 of 12 PASS, parked 0 KiB every time.
The gate passed on `0671a0c`, `c647981`, `c985fcc` and `078bcb2` the same
evening. First sighting.

[INFERENCE] Not the mark's layout change: it changed how heap-to-heap edges
are scanned, and a structure held by a root is retained whole either way. The
retention is the conservative stack scan doing what it does with a stale
word; the gate's arm needs every parked stack clean of it.
