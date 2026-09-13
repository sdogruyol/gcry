# The crash report was dying inside itself, and it had 4 720 bytes to work in

Date: 2026-09-13 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree: `08ebc5f` + this
change · knobs `GCRY_SEGV_REPORT_STACK=1`, `GCRY_POISON_HOLDERS_FAULT=1|2|3`

`make poison-holders` went red on the x86_64 GitHub runner three times in two
days — 2026-09-12 twice, 2026-09-13 once — always with the same output:

```
heap-holder: NOT named the planted holder at 0x7ff684260360
stack-holder: NOT named a stack slot
no-heap-holder: heap section reported a holder that was never planted
FAIL: heap-holder: the heap search did not name 0x7ff684260360. What it said:

gcry: holders — looking for words pointing into [0x7ff6820de0a0, 0x7ff6820de1a0), the range gcry released
```

The header, and then nothing. Read as a search that found nothing, three times,
including by me: the first response was to revert the crash path to
byte-identical code, and the run after that was green, which looked like a fix.
Locally it never reproduced — 80+ runs, including under `taskset -c 0` and
`-c 0,1` to imitate a two-vCPU runner, and 12 full gate runs.

## What the report was actually doing

Adding two `RawOut` debug prints inside the search made it fail **every** run
locally. That is the same observation this repo already wrote down in August —
"gating the printing of the shared walk behind a flag put one more call frame on
every line of the crash report, and `make poison-holders` then failed twice" —
and it points at depth rather than logic.

Measured with `GCRY_SEGV_REPORT_STACK=1`:

```
gcry: report stack — entering, alt stack 0x55a535f734f0 + 8192 B, used 3472 B, left 4720 B
```

**8 192 bytes of alternate signal stack, 3 472 of them already spent when the
handler is entered, 4 720 left** — for a report that walks the explicit root
set, every live block in the heap and every fiber stack, each frame carrying a
line buffer of 352 to 512 bytes, and then asks the same three questions again of
the holder it found. It was running out of stack, and on the runner the
pre-report usage is a little different, so there it crossed the line and here it
did not.

## Why nothing said so

Two reasons, both structural:

1. **SIGSEGV is blocked inside its own handler.** A synchronous fault with the
   signal blocked is not a second delivery — the kernel terminates the process.
   So the report could never report its own death; the child vanished after the
   last line it had flushed. `SA_NODEFER` makes the handler re-entrant, and
   `handle` now names the section and `_exit`s rather than returning into a
   loop.
2. **Nothing knew which section it was in.** `PoisonHolders` now stamps a
   one-byte stage before each walk (roots, heap, stacks) and a flag for the
   second-level owner pass, so the re-entered handler can say
   `while searching the heap walk`.

Even with both, naming needs ~3.5 KiB of its own — the handler prologue again —
which the 4 720-byte margin could not spare. That is why the first attempt at
naming still printed nothing: the fix has to include the room.

## The fix, and the numbers after it

gcry installs its own alternate signal stack: 256 KiB of BSS, installed at
`SegvReport.install`, kept only if what is already there is smaller.

```
gcry: report stack — entering, alt stack 0x557259991920 + 262144 B, used 3456 B, left 258688 B
```

| `GCRY_POISON_HOLDERS_FAULT` | with gcry's alt stack | without it |
|---|---|---|
| `1` (explicit root set) | `while searching the explicit root set` | `rc=139`, nothing named |
| `2` (heap walk) | `while searching the heap walk` | `rc=139`, nothing named |
| `3` (fiber stacks) | `while searching the fiber stacks` | `rc=139`, nothing named |

Those three arms are now part of `make poison-holders`, which is the regression
gate for all three CI reds: a tree missing the alternate stack, `SA_NODEFER` or
the stage stamp fails it.

## A second defect, found on the way

`GCRY_POISON_HOLDERS_FAULT` crashed a plain `hello` at startup with no output at
all. The store was `@@fault_stage = STAGE_NONE` — a class variable whose
initializer *references a constant*, which gets a lazy-init guard — and writing
one from `GC.init`, before the runtime is up, faults. `0_u8` instead of
`STAGE_NONE` fixes it: same byte, no guard. Worth knowing for every future knob
read from `GC.init`, which is all of them.
