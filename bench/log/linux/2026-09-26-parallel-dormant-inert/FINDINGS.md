# `GCRY_PARALLEL_DORMANT=1` was inert on Linux for two months

**Date:** 2026-09-26 · host: QEMU x86_64, 12 vCPU (desktop session loading it;
RSS is not timing-sensitive) · Kemal `/json`, `wrk -t4 -c100 -d6s`, then two
`GC.collect`s, post-GC RSS and `/gc-stats`.

## Found

Chasing why one extra thread costs an EC1 program +63% RSS
(`../2026-09-26-ec1-extra-thread/`): past the multi-mutator boundary empty
chunks stay mapped, even across an explicit `GC.collect`. The documented
remedy for that is `GCRY_PARALLEL_DORMANT=1` (docs/POLICY.md, "RSS stretch").
It did nothing. Neither did `GCRY_PARALLEL_DORMANT_ALL=1`.

## Why

The dormant path releases empties *within* `empty_chunk_retain`
(`2687c51`, 2026-08-01, "bound Parallel empty-chunk dormant to
empty_chunk_retain", measured then at a 32 MiB budget). Two days later
`9228bb9` set the Linux process default for that budget to 0, for EC1 RSS.
From then on `can_dormant` was false for every chunk. `_ALL`'s arm also
requires `empty_chunk_retain > 0`. Darwin's default is 512 KiB, which left
the opt-in nearly inert there. No gate ran either knob.

## Measured (`before_probe.py`, then `after_probe.py` on the fixed build)

| shape | default | `DORMANT=1` before | `DORMANT=1` after | `DORMANT=1` + `RETAIN=0` after (red arm) |
|---|---:|---:|---:|---:|
| EC4 | 83.8 MB | 83.4 MB (0 MB dormant) | **19.7 MB** (65 MB dormant) | 83.3 MB |
| EC1 + one parked thread | 25.1 MB | 24.9 MB | **15.6 MB** (9 MB dormant) | 24.9 MB |

Before the fix, `GCRY_EMPTY_CHUNK_RETAIN=64M` alongside the knob gave the same
19.3 / 15.3 MB, which is what located the cause.

## Fix

Setting either dormant knob without `GCRY_EMPTY_CHUNK_RETAIN` now gives the
dormant path a budget of one Parallel threshold (64 MiB). An explicit
`GCRY_EMPTY_CHUNK_RETAIN` still wins, so `=0` reproduces the old behaviour.
That is the red arm of the new gate, `make parallel-dormant`. The gate is
multi-mutator by construction (two parked threads); a 64 MiB burst is dropped
and collected twice. Default: 54 MB RSS, 44 MB of empties kept mapped. With
the knob: 12 MB, 44 MB dormant. With the knob and a zero budget: 53 MB, 0
dormant, and the gate requires that. With the fix reverted by hand,
`--expect-dormant` fails. In CI on Linux and macOS.

## Not measured

Throughput with the opt-in (2026-08-01: "~75% `/json` at ~1.7× Boehm" at
EC4). It stays opt-in; nothing about the default changed.
