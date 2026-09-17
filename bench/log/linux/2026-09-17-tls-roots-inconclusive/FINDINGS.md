# `make tls-roots`'s control arm came out INCONCLUSIVE on Windows

## What happened

Run 35223760476, `test (windows x86_64, default)`, step "Native unit and process
GC specs":

    === is thread-local storage a root? ===
    mode: control (held nowhere; the block must die)
    main thread: tls slot 0x1ab3a525148, stack [0x4393600000, 0x4393e00000)
      the slot is OUTSIDE the stack the scan walks
    victim 0x1ab3da00180: live?=true intact=true
    INCONCLUSIVE — the control block survived with nothing holding it, so this
    host's conservative scan is finding a stale copy somewhere and neither arm
    can discriminate. The wipe above is what usually prevents that.
    … tls_roots_windows.exe --control failed with exit code 1

The control arm allocates a block, stores it **nowhere**, wipes 16 KiB of stack
and collects twice; the block must die, which is what makes the other arm's
survival attributable to the thread-local rather than to the harness. Here it
survived.

Not caused by the commit it failed on (`06fb325`, a spec-helper wait) and not
new behaviour in the collector: the same job was green on `2262a6d` an hour
earlier. It is a **probabilistic control**, and this is the first record of it
coming out the wrong way.

## Why Windows is the likely platform for it

`wipe_stack` overwrites the *stack* frames the materialisation used. It cannot
overwrite the **register file**, and gcry's Windows STW capture scans more of it
than the other platforms do: `windows_stw.cr` sets `GREG_WORDS = 80` — RAX-R15
**plus the 512-byte FP/XMM save area** — against 16 GP words on Linux x86_64.
A `VICTIM_SIZE`-byte fill loop is exactly the shape a compiler vectorises, so a
copy of the pointer sitting in an XMM register is both plausible and invisible
to a stack wipe.

That is a reading, not a measurement. Which is the point of the change below.

## What changed: the arm now names the holder instead of guessing

`bench/tls_roots.cr`'s INCONCLUSIVE branch now calls
`Gcry::PoisonHolders.search`, which walks the explicit roots, every live block
and every fiber stack. So the next occurrence says *where*:

- a named slot → the wipe is too small or too shallow, and the fix is the wipe;
- `holders — none` → the copy is in a **register**, in TLS (null on this arm) or
  in memory gcry never mapped, which for this arm leaves the register file. A
  stack wipe cannot fix that; the harness would have to stop having the pointer
  in a register at all.

Verified locally by giving the control arm a deliberate live stack holder — the
report named 8 words across 4 stacks with exact fiber and slot addresses, and
said `explicit roots: 0 of 1` and `heap: 0 word(s)` so the source was
unambiguous. Some of the reported slots were *above* the current `stack_top`,
which is the stale-frame phenomenon itself.

## Still open

The arm can still come out INCONCLUSIVE, and it still fails the job when it
does — deliberately, because an arm that cannot discriminate has not proven
anything. What is fixed is that the next one leaves evidence instead of a
hypothesis. No fix is attempted here: choosing between a bigger wipe and a
harness that never materialises the pointer in a register depends on which the
report names, and this host cannot produce the failing case.
