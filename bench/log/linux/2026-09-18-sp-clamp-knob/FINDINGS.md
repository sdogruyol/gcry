# One knob, three effects, and two of them were not documented

Date: 2026-09-18 · host: AMD Ryzen AI 9 465 (20 threads), Linux 7.2.4 · tree `71cd80f`

## Where this started

`bench/log/linux/2026-09-16-orphan-break-knobs/FINDINGS.md` recorded eleven
root-disabling knobs that `src/` reads and nothing exercises, and set one aside:

> **`GCRY_DISABLE_SP_CLAMP` hangs** `greg_roots` and `scheduler_roots` rather
> than failing them (124 = the 90 s timeout). A red arm that hangs costs a job
> timeout and reports nothing […] It needs a bounded harness before it can be an
> arm; the hang is itself worth knowing.

The hang was real and reproduced first: `GCRY_DISABLE_SP_CLAMP=1 bin/greg_roots`
made **no progress in 60 s**, stopping right after its `mode: hold` line.

## The knob does three things; `docs/HARDENING.md` described one

Its row said, in full: *"Full pthread range on other threads"*. What it actually
did, in three separate places:

1. **`gc_override.cr:19` skipped `install_stw_sp_capture`.** On Linux that call
   installs the `SIG_SUSPEND` handler — the mechanism the stop collects its
   acknowledgements through. Without it a stop signals threads and waits for an
   answer that cannot come. **That is the hang**, and it is not a slow scan: 60 s
   with no output, twice.
2. **`stw_sp_clamp_enabled = false`** — the documented effect, and the only one
   anybody wanted.
3. **`with_thread_gregs` gated on the same flag** (`linux_stw.cr:573,
   `return unless @@stw_enabled && @@stw_booted`), so disabling the clamp also
   **disabled register roots**. Measured with the clamp turned off in code
   rather than by env — which skips effect 1 and so runs to completion:

       register candidates from suspended threads: 0
       FAIL: the register scan yielded nothing while a thread was suspended —
             each_thread_greg is not reporting on this platform

   That is the v0.19.0 defect shape — the one `make greg-roots` exists to catch —
   reachable through a knob advertised as a precision/speed trade. The registers
   are captured by `copy_ucontext_gregs` regardless of the clamp, so there was
   never a reason for them to disappear with it.

## The fix, and what it measures now

The capture install is unconditional, and `with_thread_gregs` gates on
`@@stw_booted` alone. Same command that hung for 60 s:

    $ GCRY_DISABLE_SP_CLAMP=1 ./bin/greg_roots
    ok — 23 register candidates from suspended threads.      # exit 0, instant

## And the knob stops being an orphan

With the clamp genuinely off, `samples/stw_sp_clamp` reads:

| run | installed | hits | fallbacks | verdict |
|---|---|---|---|---|
| default | true | **2** | 1 | ok |
| `GCRY_DISABLE_SP_CLAMP=1` | true | **0** | 2 | *also* ok |

It passed in a state where the clamp did nothing, because its assertion is
`hits == 0 && fallbacks == 0` and a fallback counts a scan that had no SP to
clamp with. The sample now also requires `hits > 0` **on Linux** — Darwin's Mach
stop reports `hits=0 fallbacks=0` by design, which is why the weaker assertion
exists at all — and the knob is wired as its red arm in the aarch64 job:

    ./bin/stw_sp_clamp                          # ok
    __omp_shell("GCRY_DISABLE_SP_CLAMP=1 ./bin/stw_sp_clamp # "the SP clamp recorded no hits"")

Verified both directions locally (exit 0 and exit 1). Census: one more knob
exercised, one more gate with a constructed red direction, and one fewer gate
that passes when the thing it names is switched off.

## Method note, second sighting

Writing the `!` prefix into `ci.yml` through tooling produced
`__omp_shell("GCRY_DISABLE_SP_CLAMP=1 ./bin/stw_sp_clamp")` — the same
substitution the orphan-knob record caught in the Makefile two days earlier.
Caught here by reading the file back rather than by trusting the edit. The line
was written by code point in the end.

## Not claimed

That the clamp's *absence* loses a root: it does not — an unclamped scan walks
more, not less. What the knob lost was effects 1 and 3, and both are fixed.
