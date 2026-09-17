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


## The instrument does not exist on the platform that needs it

Adding the `PoisonHolders.search` call broke the Windows build on two jobs —
`undefined constant Gcry::PoisonHolders`, run 35224827564, both
`windows x86_64, default` and `windows arm64, default`. `poison_holders.cr`
opens with `{% skip_file unless flag?(:unix) %}`.

So the holders search cannot answer the question on the only platform where this
arm has actually come out INCONCLUSIVE. The call is guarded and the Windows
branch says so, which leaves the diagnosis where it was on that platform: a
stale copy somewhere, most plausibly a register, unproven.

Two consequences, and they are separate items:

- **Porting the search to Windows.** Its three sources are the explicit root
  set, every live block, and every fiber stack; none of those is inherently
  Unix. The `{% skip_file %}` is about the fault-time path it was written for —
  it runs from a SIGSEGV handler with `RawOut` — not about the walks.
- **A Windows cross-typecheck.** `make darwin-typecheck` has covered this exact
  class of mistake for the other platform since 2026-08-22, and Windows had no
  equivalent, so a five-line bench change cost two red jobs and twenty minutes.
  `make windows-typecheck` now cross-compiles `samples/hello.cr` and
  `bench/tls_roots.cr` — what `ci/windows.ps1` actually builds — for both
  Windows targets in 8 s. Observed red by dropping the guard: it fails with the
  runner's own line.


## The search now compiles on Windows

`{% skip_file unless flag?(:unix) %}` turned out to be a conservative gate
rather than a dependency. The module's three sources are the explicit root set,
every live block and every fiber stack, and everything it reaches exists on all
three platforms:

| what it calls | Linux | Darwin | Windows |
|---|---|---|---|
| `Platform.thread_sp` | `linux_stw.cr` | `darwin_stw.cr` | `windows_stw.cr` |
| `Platform.snapshotted_stack_bounds` | `linux_stack.cr` | `darwin_stack.cr` | `windows_stack.cr` |
| `Platform.last_stop_sp` | `linux_stw.cr` | — | — |
| `Thread#@system_handle` | `pthread_t` | `pthread_t` | `HANDLE` |

`last_stop_sp` was already behind `{% if flag?(:linux) %}`, and the handle types
line up per platform because each `Platform.thread_sp` takes its own. Opening
the gate to `win32` type-checks on both Windows targets with no other change,
and `bench/tls_roots.cr` now calls the search unconditionally.

**Compiling is not running, and the only Windows path that reached the search
was a failure path** — the INCONCLUSIVE arm itself. A 777-line walk executing
for the first time inside an already-failing gate would turn a bad reading into
a crash. So `ci/windows.ps1` now also runs `bench/holders_find.cr`, the harness
whose answer is known: every constructed holder must be found and a block with
none must report none. That exercises the walk on Windows while it is green.

**Verified on Windows** by that step, run 35234720654,
`test (windows x86_64, default)`:

    Windows holders search
    === does the holders search find a word that is certainly there? ===
    3 holder(s), each holding one target address in its @slot ivar
    ok   small   target 0x2475dad08b0 16 bytes — heap holders found: 1
    ok   medium  target 0x2475ec20060 512 bytes — heap holders found: 1
    ok   large   target 0x2475ec40030 98304 bytes — heap holders found: 1
    control  target 0x2475dad0820 held by nothing — heap holders found: 0
    ok — every constructed holder was found, and a block with none reports none

So the walk works there, not merely compiles: every constructed holder found at
three size classes, and the control block correctly reports none. What remains
unverified on Windows is the *stack* half of the search — `holders_find` builds
its holders in the heap — and the INCONCLUSIVE path itself, which needs the arm
to fail again.
