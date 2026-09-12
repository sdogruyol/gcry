# Thread-local storage was not a root

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `c5bb5e3` +
this change · gate `make tls-roots`

## What was found

A block whose only reference is a **main-thread `@[ThreadLocal]`** was
collected. Measured, three arms:

| arm | victim after two `GC.collect` |
|---|---|
| shipped (before this change) | `live?=false` — **collected** |
| shipped (after) | `live?=true` |
| control, pointer held nowhere | `live?=false`, both ways |

The control is what makes the first row mean anything: a conservative hit on a
stale stack slot would have made the held arm pass for a reason unrelated to
TLS, and the harness wipes 16 KB of its own frames before collecting for the
same reason.

## Why it was there, and why it stayed unseen

`dl_iterate_phdr` gives the executable's writable `PT_LOAD` segments, which is
`.data` + `.bss` together — so every **class variable** is a root. A
thread-local is in neither: `PT_TLS` is only the *template*, and the live
block is allocated per thread. Where it lands is not uniform, and that is the
whole reason this survived to 2026-09-12:

```
main thread    tls 0x7f9db13e0770   stack [0x7ffc1e8e9000, 0x7ffc1f0e6000)   OUTSIDE
spawned thread tls 0x7f9daf5fe6b0   stack [0x7f9daedff000, 0x7f9daf5ff000)   inside
```

glibc puts a spawned thread's descriptor and static TLS at the top of that
thread's own stack mapping — inside the bounds `pthread_getattr_np` reports
and above the suspend SP, so the ordinary stack scan has always covered it.
Every thread gcry spawns, and every thread a Crystal program spawns, was
therefore fine. The **main** thread's block is allocated by the loader with
the shared libraries, nowhere near its stack, and nothing scanned it.

This is the third branch of the sentence `GCRY_POISON_HOLDERS=1` prints on
every use-after-free this heap produces:

> holders — none. Nothing in the root set, in a live block or on a fiber
> stack points into it, so the pointer is in a register, in thread-local
> storage, or in memory gcry never mapped — and those are three different
> defects

Registers were covered (`ucontext` GP spill for suspended threads,
`MonitorGate.enter` for the one thread that is never suspended, 2026-09-12).
Thread-local storage had never been tested. It is now the arm that a knob can
break on purpose.

## The fix, and its size

At `GC.init`, on the main thread — the only context that can take the address
of its own thread-local, and the context this cache is already built in — the
range containing a gcry-owned `@[ThreadLocal]` anchor is added to the static
root ranges.

Sizing mattered. The first version took the **whole containing mapping**:

| version | range |
|---|---|
| containing mapping | **843 776 bytes** (824 KiB) |
| executable's `PT_TLS` `p_memsz` window | **128 bytes** |

824 KiB is the loader's mapping, shared with data that has nothing to do with
this program's thread-locals: ~100k words of conservative scan per collection
and every one of them retaining whatever it looks like. `PT_TLS` `p_memsz` is
exactly the executable's TLS block; the anchor is inside it, so a window of
`memsz` either side of the anchor covers the block wherever in it the anchor
sits — without depending on the variant-II rule that the block ends at the
thread pointer — and the window is clipped to the containing writable mapping
so the excess can never reach an unmapped page. 16 words per collection.

## What it does not fix, measured

The open **live large object released under load**
(`../2026-09-12-thread-churn-large-uaf/`) is not this. The 824 KiB version
*looked* like it was — 6 of 12 against 11 of 12 — and that was the false
retention, not the roots. With the range at 128 bytes:

| harness | `GCRY_TLS_ROOTS=1` | `GCRY_TLS_ROOTS=0` |
|---|---|---|
| `thread_churn_uaf` (headerless), 24 concurrent | 15/24 | 15/24 |
| `thread_churn_uaf_headers`, 24 concurrent | 9/24 | 14/24 |
| committed harness, `CHURN_ATTEMPTS=18`, poisoned arm | 15/18 | 14/18 |

The committed harness is the apples-to-apples one and it says nothing moved.
The hypothesis is retired: the missing reference in that defect is not in
thread-local storage. That leaves the sweep losing a live block's occupancy —
which is where `../2026-09-12-thread-churn-large-uaf/` already pointed — and
the two remaining branches of the holders sentence unchanged.

Recording the 824 KiB number is the point of this section. A wider
conservative range moves a use-after-free rate *by retaining garbage*, and a
run that had shipped it would have read as a fix.

## Not measured

Darwin (TLV, allocated lazily off `_tlv_bootstrap`, not in any `__DATA`
section the dyld walk takes) and Windows (`.tls`, copied per thread through
the TEB). Both plausibly have the same hole and neither has a host here.
`GCRY_TLS_ROOTS` is Linux-only and says so; the question is on `ROADMAP.md`.
