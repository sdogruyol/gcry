# `make nursery-headers` was testing a major

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `fcff46e` · `python3 bench/gate_arm_census.py`

CI's "Nursery HTTP::Headers regression" built `bench/nursery_headers.cr`
without `-Dgcry_block_headers`. `Heap#nursery_enabled=` is a no-op on
that layout (Phase 7.3), so `minor_collect` returned immediately and
the names were string literals still on the stack. Both would have
stayed green through a KIND_HASH walk that noscans `@entries` and does
not mark keys — the 2026-08 HTTP keep-alive UAF.

Auto-layouts already skip `Hash(HTTP::Headers::Key, …)`. Conservative
chase of the blob keeps those keys; the defect is the precise path.

## What changed

Green builds `-Dgcry_block_headers`, requires the nursery actually on
and a hash layout that walks keys, plants a nursery-allocated name off
the stack (`NoInline` + `clear_stack`), and requires it to survive.
`--disabled` installs the pre-fix layout (noscan `@entries`, no
key/value walk) and requires that name to vanish. Dropping
`-Dgcry_block_headers` or the zeroed walk reddens the gate (exit 64)
rather than hiding it.

## Measured

| arm | result | notes |
|---|---|---|
| green (`-Dgcry_block_headers`) | **8/8** exit 0 | 0.2 s |
| `--disabled` | **8/8** exit 0 | young name gone, Connection kept |
| `GCRY_SOUND=1` green | exit 0 | harness re-enables nursery after the profile |
| headerless (compile default) | exit **64** | nursery never on |
| `--disabled` with the walk restored | exit **64** | guard, 0.0 s |

`HTTP.keep_alive?` after `--disabled` hangs (Request construction walks
the dangling entry). The red arm only checks the name is gone.

CI x86_64 (`a61e2d6`) lost the `--disabled` arm: the young name survived
on the stack (`X-Nurs-670371`). The pin is a static root and the minor
skips the stack, so the Hash walk is the only path.

## Census

```
harness-driven gates:              99
red direction constructed per run: 64
red direction established by hand: 35
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 63 / 36 → 99 / 64 / 35.** `nursery-headers` moved: recipe 1,
harness 0. The recipe now has `-Dgcry_block_headers` and `--disabled`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
