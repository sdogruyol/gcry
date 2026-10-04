# The collector's own stack held other threads' registers

Found through `make fp-register-root`'s red arm on macos-15-intel, which
started keeping its victim on the `layout-removal` branch (`b715fa5`) while
`c985fcc` dropped it.

## What the gate saw

`GCRY_DISABLE_GREG_ROOTS=1 bin/fp_register_root` must collect a block whose
only reference is `xmm8` of a suspended thread. On macos-15-intel:

| build | victim kept |
|---|---:|
| `c985fcc` | 0 of 8 |
| `c985fcc` with `GCRY_DISABLE_LAYOUT=1` (no boot registration) | 0 of 3 |
| `b715fa5` | 12 of 13 |
| `b715fa5` built with `-Dgcry_hl_assert` | 0 of 3 |
| `b715fa5`, victim allocated by the holder thread | 5 of 6 |
| `b715fa5` + the fix | **0 of 8** |

macos-latest (arm64) dropped it every time on every build. `GCRY_LIVE_ATTR=1`
put the victim's first mark on a **stack** root (`stack=96` atomic bytes, 0 on
`c985fcc`), and moving the allocation into the holder thread did not help, so
the word was a copy of the holder's `xmm8`, not something main left behind.

## Why

`Platform.capture_thread_state` (darwin_stw.cr) reads each suspended thread's
general-purpose and FP/SIMD state with `thread_get_state` into buffers in its
own frame — 272 + 528 bytes plus the merged row — and copies them into the
`StwSlots` table, which is what the register roots scan. The buffers stay
behind when the frame returns. The collector then scans its own stack from
its SP at the time (`scan_mutator_stack` → `Roots.scan_mutator`), and when that
call chain runs deeper than the stop did, the dead copies are inside the
window: another thread's registers, from this stop, as roots of the
collector's own thread. Register roots switched off no longer switched them
off, and with them on they are a second, stale copy of every register — a
previous stop's values included, wherever the frames line up.

The entry scrub (`GCRY_COLLECT_SCRUB`) cannot reach them: it runs at entry,
and the copies are written later, during the stop. Whether a copy lands in the
window is a question of frame sizes, which is why a branch that only deleted
code elsewhere turned it on, and an instrumented build of the same branch
turned it off.

Windows has the same shape: the stop's loop reads `CONTEXT_FULL`, XMM
included, into a 1 248-byte buffer in its frame. Linux does not: the suspend
handler saves the registers on the suspended thread's own stack, where the
scan of that thread is meant to find them.

## Fix

Both buffers are cleared once copied, on the failure paths too, behind an
empty `asm` with a memory clobber, because to the optimiser they are stores to
a dead local (`scrub_register_copy` in darwin_stw.cr and windows_stw.cr).
