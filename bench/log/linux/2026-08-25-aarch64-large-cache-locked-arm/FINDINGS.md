# aarch64: the locked arm of `large-cache-race` faults

## The observation

CI run 32862284372, job `test (aarch64 native)`, step
*Unit + process specs + STW SP + fork on aarch64*:

    locked (default):    1 of 5 failed   Invalid memory access (signal 11) at address 0xff54b84da00
    FAIL: the locked arm faulted 1 of 5 — the allocator and the trim are not serialised
    unlocked (old):      5 of 5 failed   Invalid memory access (signal 11) at address 0xff22ac9e21a

The control arm behaves exactly as designed — 5 of 5 — so the gate itself is
sound and the green side is evidence. What is new is that the **default** arm,
the one with `take_large_free` and the trim's detach serialised under
`@alloc_lock`, faulted too.

## Why it matters and what it is not

The same gate is green on x86_64, and has been green there across every run in
this session. This is the first time it has been seen red on the locked arm.

It is the same family as an x86_64 observation that could not be reproduced:
`GCRY_UNMAP_GUARD=1 make large-cache-race` returned **2 of 40** once and then
**0 of 48** across two later sweeps. Under the guard a released range stays
mapped `PROT_NONE`, so a stale access faults instead of landing in whatever the
kernel put there next — which is why the guard can see on x86_64 what the
default arm apparently sees unaided on aarch64.

## Rate

Unknown. One red run, and the same job passed on the run before it
(32857778274) and the run after (32864614391). At 5 attempts per gate run the
rate is somewhere below 1 in 5 attempts, and a green run costs nothing to
produce, so **a green aarch64 job is not evidence that this is closed**.

## Open

This is not fixed. It is a use-after-free on the default configuration of a
supported platform, and it should either be reproduced and closed or stated
plainly in the release notes before 0.21.0 is cut.
