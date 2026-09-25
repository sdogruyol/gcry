# The churn gate's "wild pointers" read as freed malloc blocks

**Date:** 2026-09-25 · host: Linux 7.0.0-31-generic x86_64 (QEMU), glibc 2.43,
Crystal 1.21.0 · `bench/segv_report.cr`, `src/gcry/segv_report.cr`

## The two sightings

`make thread-churn-uaf` faulted twice on CI outside gcry's heap span, both in
an arm with `GCRY_THREAD_UNSTAGE_ON_DEATH=1`:

| date | run | arm | fault address |
|---|---|---|---|
| 2026-09-19 | `35424121362` | poisoned, headerless | `0x55816aff0` |
| 2026-09-22 | `35709742955` | guarded, headers | `0x55797df8d` |

Both were reported as "never a gcry allocation", and read as wild pointers
(`2026-09-19-churn-out-of-span-sighting`, `2026-09-22-three-reds`). The
region line added after the first cannot help with this shape, because the
address itself is in no mapping.

## The reading

Both addresses are x86_64 PIE-region addresses shifted right by twelve:
`0x55816aff0 << 12 = 0x55816aff0000`, `0x55797df8d << 12 = 0x55797df8d000`.
That is the brk malloc heap's neighbourhood. glibc 2.32+ stores the link of a
freed tcache or fastbin block as `(block >> 12) ^ next` (safe-linking), so a
block freed with no successor holds exactly `block >> 12` in its first word.
A stale pointer loaded out of such a block and dereferenced faults at an
address of this shape.

So the likeliest victim is a **small `malloc` block (≤ 1032 bytes, C heap),
freed and then read as a pointer**, not any gcry allocation, which also fits
the holder searches finding nothing. `[INFERENCE]` for the CI sightings: the
shifted-back addresses were not checked against those processes' maps. The
low twelve bits of `block >> 12` are arbitrary, so an offset the reader added
cannot be separated from them.

## What changed

`report_faulting_region` now also asks whether `addr << 12` lies in a writable
mapping when `addr` itself lies in none, and if so says so, with the mapping,
instead of calling the address wild. `make segv-report` has a `tcache` arm
(glibc only): it frees a fresh 200-byte `LibC.malloc` block, loads the word
glibc left in it and dereferences that — the real mechanism, not a
synthesized address:

    gcry: SIGSEGV at 0x62c163944 — outside gcry's heap span [...]
    gcry: no mapping holds that address, but 0x62c163944 << 12 = 0x62c163944000
          is in the writable mapping [0x62c163939000, 0x62c16395a000)
    gcry: that is glibc safe-linking — a freed tcache/fastbin block with no
          successor holds its own address >> 12 — so the likeliest reading is a
          pointer loaded out of a small malloc block (C heap, not gcry's) that
          had already been freed, in or near that page

Red: with the branch disabled the arm reports "wild pointer" and the gate
fails. `--control` stays silent. `make segv-region-report` unchanged.

600 children on this host pinned to two CPUs (`taskset -c 0,1`, as CI's
two-core runner), both layouts × guarded and poisoned arms with the
amplifier, 150 each: **0 of 600** faulted. It stays CI-only: two sightings
since 2026-09-19, one per ~24-child arm when it happens. The next one reports
the reading above instead of "wild pointer". `[INFERENCE]` If it names a page
of `[heap]`, the victim is a main-arena block, most likely one the main
thread (the one collecting in this workload) allocated, since glibc gives
other threads arenas of their own while arenas are available.
