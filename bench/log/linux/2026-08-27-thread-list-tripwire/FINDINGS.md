# The thread list is the victim, watched: it holds 7, then reads zeroed — or worse, a payload pointer

2026-08-27, Linux x86_64. The tripwire built for the `0x18` crash
(`src/gcry/thread_list_tripwire.cr`, wired in 76f33c5) run for the first time.
It confirms the model it was built on, and the faults it takes *itself* say more
than the line it prints.

## Protocol

`bench/dormant_flush_race.cr --child` run directly, 160 children per arm,
interleaved — every iteration launches 2 on-arm + 2 off-arm children
concurrently, so both arms sample the same load (`bench/tlw_batch.sh`). One
binary; the arm is `GCRY_THREAD_LIST_TRIPWIRE=1` against `=0`, both under
`GCRY_MOSTLY_EMPTY=1 GCRY_UNMAP_GUARD=1 GCRY_SEGV_REPORT=1`. 120 s deadline per
child; none hit it.

Engagement: every clean on-arm child ends `tl_max 7` (130 of 130), every
off-arm child `tl_max 0`. Both arms are what they claim to be.

## The numbers

| arm | children | failed | `0x18` | faults inside the walk | other |
|-----|---------:|-------:|-------:|-----------------------:|------:|
| tripwire on | 160 | 30 | **4** | **26** | 0 |
| tripwire off | 160 | 34 | **33** | — | 1 |

The totals match (30 against 34). The tripwire does not add crashes and does
not remove them — it **moves** them: 33 unexplained `0x18`s on the off arm
become, on the on arm, 4 `0x18`s plus 26 faults taken by the walk itself, at
real addresses, with the guard naming the chunk.

Aside worth its own line: under this batch's load — four children sharing the
machine — the off-arm rate is **21% per child**, against the 1–3% every serial
batch this month has fought with. The cheap reproducer the page-release log
asked for is: run four at once.

## Every on-arm `0x18` was announced first

All 4 of 4, and no `0x18` without it:

    gcry: the runtime thread list reads empty before Thread.lock — it held
    7 threads, so the list object's memory has been zeroed under it. collection 184
    gcry: SIGSEGV at 0x18 — outside gcry's heap span …

(collections 108, 184, 227, 229 — deep into the run, never at boot.) The model
the tripwire encodes is confirmed on every instance it could observe: the list
held all 7 threads for a hundred-plus collections, then read empty at the walk
one instruction before `Thread.lock` faulted. The memory was zeroed under a
live, marked object — which is what the dying-type audit's zero
(`dying_deaths 0` on `Thread::LinkedList`, `../2026-08-23-zeroed-object-0x18/`)
already said from the other side: nothing sweeps it; something writes it.

## The 26 faults the walk took are the better evidence

Backtrace for all 26: `check_thread_list_before_lock ← stop_world`, the
tripwire's own unlocked walk. Six land in a chunk the guard can still name:

    gcry: SIGSEGV at 0x7fc689be2050 — in a chunk gcry RELEASED — base
    0x7fc689be2000, 45056 bytes, large-object release, at collection 61; the
    write is 80 bytes into it. Collections since: 0. First user word at
    release: 0x5c (type_id 92)

The other 20 read "inside the heap span but in no live chunk". All 26 share:

- a **large-object release** territory — 45056 bytes is exactly the bench's
  40 KiB payload plus header, and `0x5c` is the bench's FILL byte;
- **`Collections since: 0`** — released at the collection the walk faulted in
  or the one before;
- the faulting address is **`+0x50` from a chunk base in all 26** — the same
  final twelve bits every time, across different children and different
  addresses.

That last one is the finding. The walk dereferences a fixed ivar offset off a
pointer it read out of the list, so a constant fault offset means the *value it
read* is a constant offset from a chunk base — a structured pointer, plausibly
exactly what `GC.malloc_atomic` returns for a payload block. The thread list is
not being overwritten with noise; a slot that should hold a `Thread` reference
(or the list's own `@head`) holds a **pointer to a freshly released payload
block**.

So the damage has two presentations, and the tripwire separates them cleanly:
the kernel has already reclaimed the page → reads zero → tripwire line, then
`0x18` in `Thread.lock`; the page still carries its last contents → the walk
follows a payload pointer into guarded territory and faults with the chunk
named. Same victim, same window, one collection wide.

## The off arm produced a third presentation

One off-arm child (`off-30-b`) died not on `0x18` but on
`pthread_mutex_unlock: Invalid argument` raised from
`Thread::LinkedList(Thread)#delete` during a worker's exit — the list's
`@mutex` no longer a valid mutex, i.e. the same object's memory clobbered but
non-zero. Every presentation this family has shown — the null `@mutex`, the
EINVAL mutex, the payload pointer in a link — is one object's memory being
overwritten while live.

## What this retires, and what it aims at

- Retired: "outside gcry's heap span, so a swept object is not the
  explanation" as the last word on `0x18`. The `0x18` is the *second* fault of
  the sequence; the first read, one instruction earlier, is inside the heap, in
  large-object release territory, at `+0x50`.
- Retired for this defect: the small-object page-release walk as the only
  suspect. Every named chunk here is a **large-object release** — the
  `trim_large_cache` / large-release path, the one this bench was originally
  written about, is back in the frame.
- Open: who writes a payload-block pointer (and later zeros) over a boot-time
  runtime object. The regular `+0x50` says the writer is structured — a
  freelist link, a cache entry, or an allocation landing at an address the
  collector believes it owns. The next instrument should watch the list
  object's *page* for the write itself (the corrupting store, not the crash
  that follows it), which is what the page-release log said this hunt needs.

Raw child logs: `raw/` beside this file (not committed, 320 files).
