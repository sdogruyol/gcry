# Three reds on a docs-and-harness commit, and what each one was

**Date:** 2026-09-22 · CI run `35709742955` (tree `62ef2e3`) · host for the
local numbers: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0

The commit changed `bench/thread_census_names.cr`, the Makefile and two
documents. Three jobs went red, none of them for that change.

## 1. `thread-census-symbolize` — the fix one target short

Same root cause as the flake fixed in the commit itself: a frame to
resolve needs a task parked in a syscall, and without a planted one the
subject is whichever peer happens to be asleep. The two *location* arms
were pointed at the new `--parked` probe; this target was not, and it is
the one that went red (`no frame landed in this binary`). Pointed at it
now: 3 runs, `2 of 2 reported frames resolve` each.

## 2. `thread-churn-uaf` — a sighting, half of it dropped

`guarded 1 of 24` on the **header** layout:

```
gcry: SIGSEGV at 0x55797df8d — outside gcry's heap span
      [0x7fdb51e00000, 0x7fdb52c84000) — never a gcry allocation, so a
      swept object is not the explanation
```

Local, same binary, same arm (`GCRY_THREAD_UNSTAGE_ON_DEATH=1
GCRY_UNMAP_GUARD=1 GCRY_SEGV_REPORT=1`): **0 of 40**. So this stays a CI
rate, like the rest of this family.

What the sighting could not say is what that address *is* — and the
region report added this cycle answers exactly that, on the line **under**
the one quoted. The harness was keeping one line. It keeps the whole
`gcry:` block now (up to 8 lines), so the next out-of-span fault arrives
with its mapping, permissions and distance below the mapping's top
instead of as one number.

## 3. Windows `tls-roots` — red once in 90, and unable to say why

```
main thread: tls slot 0x1f1d0b55148, stack [0x31b3200000, 0x31b3a00000)
  the slot is OUTSIDE the stack the scan walks
victim 0x1f1d4100180: live?=false
FAIL a block whose only reference is a main-thread `@[ThreadLocal]` was collected.
```

The stack line is not evidence — the slot is *never* in the stack; that
is the premise of the gate. What the output never printed is the range
gcry actually pushed for the TLS block, which is the thing under test.
`Platform.tls_root_range` existed on all three platforms and nothing read
it. The harness prints it now, with which side the slot fell off and by
how many bytes:

```
main thread: tls slot 0x78432e262530, stack [0x7ffd030ef000, 0x7ffd038ed000)
  the slot is OUTSIDE the stack the scan walks
  gcry's TLS root range: [0x78432e2624d0, 0x78432e262570) — the slot is INSIDE it
```

The Windows range is `anchor ± tls_memsz` clipped to the writable region
`VirtualQuery` reports around the anchor, so a next red distinguishes the
two candidates on sight: a slot outside a correctly-sized window (the
anchor moved) from a window the clip cut short (the TLS block straddles
two protection regions). Both were guesses today and neither can be
chosen without that line.
