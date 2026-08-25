# The locked arm of `large-cache-race` faults — and it is not aarch64-only

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

**1 of 60.** Measured on the aarch64 runner with `LARGE_CACHE_RACE_ATTEMPTS=60`
(CI run 32878170978, dispatch-only `aarch64-lcr-rate` job):

    4 workers × 20000 rounds of 40960 B, one trimmer, 60 attempts per arm
      locked (default):    1 of 60 failed
      unlocked (old):     60 of 60 failed   Invalid memory access (signal 11)

The control arm is **60 of 60**, so the gate is sound and its green side is
evidence. With the earlier sighting that is **2 faults in 65 attempts**, about
3%, against **0** for the same gate on x86_64 across every run in this session.

A green aarch64 job is therefore not evidence that this is closed: at 5
attempts per push run, most runs will be green.

## Open

This is not fixed. It is a use-after-free on the default configuration of a
supported platform, and it should either be reproduced and closed or stated
plainly in the release notes before 0.21.0 is cut.


---

# It is not aarch64-specific, and the backtrace names it

## Reproduced locally on x86_64

Running the gate on this laptop with more attempts than the default five:

    locked (default):    3 of 10 failed        (no knobs)
    locked (default):    2 of 10 failed        (GCRY_SEGV_REPORT=1)
    locked (default):    1 of 10 failed        (GCRY_RELEASE_LEDGER=1)

The knobs make no difference; the default configuration faults. The same
commit that CI's x86_64 job passes on. So the rate is **machine-dependent**,
not architecture-dependent: roughly 10–15% per child on a many-core laptop,
about 1.3% on the aarch64 runner, and apparently zero on the two-core x86_64
runner. A green `Large-cache race` step means the runner is slow, not that the
defect is gone.

It is also **not new**: the worktree at `b007984`, before the bounds repair,
faults 2 of 10.

## What faults

`GCRY_SEGV_REPORT` had to be installed by the harness to say anything — gcry
arms it from its collect callback and this child barely collects, so the knob
was silently inert. With it armed, three children in a row said the same thing:

    gcry: SIGSEGV at 0x7eff25e73000 — in a range gcry RELEASED and unmapped —
    base 0x7eff25e73000, 45056 bytes, large-object release, at collection 0;
    the write is 0 bytes into it. Collections since: 0.

The fault address **is the chunk's own base** — `ChunkHeader.next`, offset 0 —
and "collection 0" means no collection was involved: this is the explicit
`free` → `cache_large_chunk` → `trim_large_cache` path. The two aarch64
addresses ended in `008`, which is `mapped_bytes`, the next field along.

The backtrace names the walk:

    Gcry::Heap#update_heap_bounds_after_unmap
    Gcry::Heap#trim_large_cache<UInt64>
    ~procProc(Thread, Nil)

## Why a walk under `@alloc_lock` can meet an unmapped chunk

`unlink_chunk` removes a chunk from `@chunks` under `@alloc_lock` before
anything unmaps it. But **`@chunks` is mutated under two different locks**:
`map_chunk` reaches the list from `refill_size_class` holding the *size-class
freelist* lock, not `@alloc_lock`. A prepend interleaved with an unlink can
leave a removed chunk reachable through `next`, and the walk then dereferences
it after `munmap`.

That is the same two-lock problem behind the heap-bounds exclusion found
earlier the same day (`2026-08-24-acikturkiye-live-string-uaf`): one list,
two locks.

## What was changed, and what it is worth

`update_heap_bounds_after_unmap` no longer walks the `next` chain. It reads the
lowest base and highest end off the **chunk index** — a flat array, sorted by
base, of chunks that are by construction still mapped, guarded by one lock that
nothing takes `@alloc_lock` inside — and reads *and* stores the bounds inside
that lock, with `note_mapped` using the same lock for the same fields. O(1)
instead of O(chunks), and no dereference of a pointer another thread may have
freed.

Measured **interleaved**, alternating binaries child by child so both arms see
the same machine:

| Arm | SIGSEGV | children |
|-----|--------:|---------:|
| before (`708ee7b`) | **9** | 60 |
| after | **4** | 60 |

Fisher exact p ≈ 0.24. **Not significant**, and a later 45-child post-fix batch
returned 0 while an earlier 40-child pre-fix batch also returned 0 — this
machine's rate swings by more than the effect being measured.

So: one confirmed dereference site is gone and the rate looks roughly halved,
but the defect is **not closed**. The real fix is to put `@chunks` under a
single lock; every walk of it is exposed to the same race until then. Non-
interleaved comparisons on this machine are worthless, which is how the first
"before 2–3 of 10, after 0 of 60" reading was produced and why it was dropped.
