# The crash had the answer in gcry's tables and nobody asked

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none` · tip @ `f27396a`+

`Invalid memory access at 0x7f1700000149` is everything the 2026-08-10 soak left
behind. At the moment it faulted, the collector could have said whether that
address was inside its heap span at all, which chunk and size class it landed in,
whether the block holding it read used or free, and what sat at the block's
start. All of it was in memory. None of it was asked for.

`GCRY_SEGV_REPORT=1` asks. On SIGSEGV or SIGBUS it prints what the heap knows
about `si_addr` and then hands the signal back to Crystal's handler, which
prints its message and backtrace exactly as before — this adds lines and removes
none.

## Two things it had to be taught, both by being wrong first

**Installing at `GC.init` accomplishes nothing.** Crystal installs its own
SIGSEGV/SIGBUS handler during `init_runtime`, after `GC.init`, with
`sigaction(..., nil)` — discarding whatever was there and keeping no chain. The
first version printed *nothing at all*. It now installs from the first
collection, by which point Crystal's handler is in place and becomes the one this
chains back to. The cost is stated rather than hidden: a fault before the first
collection is not explained.

**The poison is invisible to `si_addr`.** `0xdeadf2eedeadf2ee` is
**non-canonical** on x86_64, so dereferencing it raises #GP rather than a page
fault, and the kernel reports `si_addr` as **0**. A reporter that matched on the
address would never fire on the case it exists for — and the first one did not.
When the address cannot say, the *registers of the faulting context* are asked
instead, using the same ucontext offsets the collector already scans suspended
threads with. Measured, a poisoned use-after-free now prints:

```
gcry: SIGSEGV at 0x0 — gcry's freed-block poison (GCRY_POISON_FREED) is in the
faulting context. Something followed a pointer read out of a block that had
already been freed: a use-after-free, not a wild pointer
```

An address of 0 with no poison in the context gets its own line, because the
ambiguity is real: on x86_64, "0" also means "non-canonical pointer" and the
report says so rather than asserting a null dereference.

## The gate

A crash reporter can only be tested by crashing, so `make segv-report` forks a
child per fault shape and checks the diagnosis names the right one:

| arm | must say |
|---|---|
| poison | freed-block poison, from the faulting context |
| free-block | in a FREE block |
| used-block | in a USED block |
| outside | outside gcry's heap span |

The last arm's address is deliberately **canonical** (`0x00005eadbeef0000`): a
non-canonical one would fault as #GP with `si_addr` 0 and exercise the wrong
branch — which is how the poison lesson above was learned.

`--control` runs the same faults with the knob off and requires **no** gcry line
on the two signal arms, so the diagnoses are attributable to the reporter.

## What this buys

The 2026-08-10 value admitted three readings and the argument could not be
settled. Every one of them is now a *different sentence*: a swept object reads
"in a FREE block", a reissued one reads "in a USED block" with the first word of
its payload printed, a wild pointer reads "outside gcry's heap span", and a
use-after-free of poisoned memory says so in as many words. The next crash of
this shape forecloses at least two readings before anyone opens an editor.

It does not find the bug, and it does not claim the bug is a use-after-free.
