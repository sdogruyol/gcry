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


---

# Same day, continued: the chain walked to its root, and the root fixed

Eleven more instrument iterations, one wrong instrument withdrawn, one fix,
one clean batch of 100. Every step below is 100–120 children under the same
protocol (4 concurrent, `GCRY_MOSTLY_EMPTY=1 GCRY_UNMAP_GUARD=1
GCRY_THREAD_LIST_TRIPWIRE=1`), and every claim is the *unanimous* reading of
that step's crashed children — none of these are majorities.

## Step by step, each link measured

1. **Who writes over the object?** `set_free`/`set_used` hooks on every block
   transition: 21 of 21 crashes carried
   `a block set_used (hand-out) covers the thread list object … prior flags
   0x81` — FREE|SWEPT. The allocator re-issued the live list's own block, and
   the backtrace at the hand-out is one stack, all 21: `GC.free →
   trim_large_cache → __crystal_malloc64 → alloc_old_small_locked` — the
   32-byte closure `trim_large_cache` allocates for its detach lambda. That
   closure's captured locals are large-block user pointers, which is why the
   overwritten list held pointers shaped exactly like `chunk base + 0x28`.
   The zero-fill of malloc's clean path is the other presentation ("held 7,
   reads empty"). The lottery between them is just who claims the block.
2. **Why was it on a freelist?** `SWEPT` says the sweep freed it. The sweep
   report shows `marked no, header gen 0` with static roots at full width —
   and always on a **major**.
3. **Did the mark ever see it?** Per-cycle candidate tracking: 35 of 35 fatal
   cycles read `offered to the mark this cycle` — the BSS slot was scanned
   and the value delivered. Not a root-coverage hole.
4. **Why was the offer rejected?** The reject-reason probe: 215 of 215 reject
   lines across 44 fatal children read `find_block returned nothing`. The
   lookup, not the root, not the gate (`clear_nursery_marks` explains the
   gen-0 shape: the boot chunk is a nursery chunk, so every minor clears the
   promoted block's gen bits and every healthy cycle re-marks it).
5. **Why does the lookup fail?** The chunk is *gone from the chunk index* —
   first seen **at the suspension**, i.e. the loss happens outside the pause.
   A linear pass says: absent from the array, **0 order inversions**, and a
   base-identity pass (immune to a corrupted `mapped_bytes`) agrees. Not
   unsorted, not header-blinded: the entry is not in the visible window.
6. **Which operation loses it?** None. The `index_remove` hook (range *and*
   base identity): 0 hits. A verifier at the end of **every**
   `index_insert_locked` / `index_remove_locked`: 0 hits across 17 fatal
   children. Every index operation completes with the entry present, and the
   entry is nonetheless absent at the next suspension.

One instrument was withdrawn on the way: the first version of the linear pass
took `@index_lock` inside the stopped world and hung 18 of 100 children on
the deadline — a mutator suspended mid-index-operation still owns that lock.
The walk is unlocked now, and those 18 timeouts were the instrument's own.

## The mechanism

`index_insert_locked` wrote, in this order: shift the tail right
(`a[count] = a[count-1]`, …), write the new slot, **then**
`@chunk_index_count += 1`. `chunk_containing` reads the index *unlocked*
during a stop — the documented rationale being that only the collector
touches it then — and `stop_world` suspends by signal, anywhere. A mutator
frozen between the shift and the increment leaves a window in which the top
entry has been copied to `a[count]` while `count` still hides it: the
collector sees a **sorted array whose last entry does not exist**, for that
entire collection.

That closes every observation at once. Absent-yet-sorted; no remove; every
operation verifying clean at its own end (the increment has happened by
then); first seen at the suspension (the suspension is what freezes the
window open); load-dependent (more mutators mapping chunks, more chances to
freeze one mid-insert); and always this victim — the highest-addressed chunk
is always the **boot chunk**, mmap hands later chunks lower addresses, so the
hidden last entry is always the chunk holding the runtime's own objects, and
the only one of those whose sole reference lives outside a re-scanned stack
is `Thread::LinkedList`. The `0x18` at `Thread.lock`, the
`pthread_mutex_unlock: EINVAL` at thread exit, and the payload pointers the
walk followed were one lost mark wearing three coats.

## The fix, and its measurement

Publish order inverted: duplicate the top entry into the new slot, publish
`count + 1` with a release store, then shift. Every state a suspended thread
can now expose is a sorted array with at most one *adjacent duplicate* —
harmless to a binary search — and never one with an entry hidden.

Same binary shape, same arm, same load, 100 children:

| | failed | `0x18` | walk faults | tripwire | GONE |
|---|---:|---:|---:|---:|---:|
| before (raw6–raw14, per 100) | 8–44 | — | — | — | every crash |
| **fixed** | **0** | **0** | **0** | **0** | **0** |

Fisher on 0/100 against the weakest baseline in this file (8/100) is
p ≈ 0.003; against the typical 20–30 per 100 it is beyond argument. The
instruments stay in the tree under the same knob, because the next defect in
this family will want them: the watch (`ThreadListWatch`), the phase probes,
the offer/reject reporter, and the per-operation index verifier.

Raw logs for every step: `raw2/`–`raw14/`, `rawfix/` beside this file (not
committed).


---

## The field sighting, and what the closed family re-measures to

While this file was being written, acikturkiye production (0.21.1, built
`-Dpreview_mt -Dexecution_context` — multi-threaded, so the mid-insert window
is reachable) died at **`0x4` in `String#empty?`** reached from Kemal's
`unescape_url_param`, on a 200 route with URL parameters. That is the second
sighting at that exact frame — the first read `0x0`
(`bench/url_params_hash.cr`'s header). `0x4` is `@bytesize` of a null String
reference: a value slot of a live `Hash(String, String)` reading zero — the
same shape as the `@mutex` of a live list reading zero, and the index-hide
kills whole chunks at a time, so any boot-adjacent object qualifies as a
victim. **[INFERENCE]** the fix plausibly covers it; a local closed loop was
attempted and is reported honestly below: 30 minutes of `wrk -t4 -c64` on the
parameterised tags route did **not** reproduce the crash on the 0.21.1 binary
(268k requests, clean) — the field rate is below what half an hour resolves —
and the fixed binary ran the same load clean. Production is the only
instrument with enough hours; 0.21.2 exists so it can be pointed at this.

## The family's other arms, re-measured on the fix

- **Plain mostly-empty arm, no tripwire** (the instrument ruled out): 0
  crashes of 100 under the same 4-concurrent load whose baseline was ~21%
  per child. Two children hit the 120 s deadline with no output — hangs, not
  faults, previously seen at low rate in this gate's family and not new here.
- **`make page-release-corruption`, 40 per arm**: mostly-empty **0 of 40**
  (engaged, 647 MB released), control 0 of 40. The "cannot currently be
  measured" verdict in `../2026-08-26-page-release-unlink/` is withdrawn —
  the unstable 2–11 baseline those five nulls were measured against was this
  defect's lottery, not measurement noise.
- **`GCRY_PAGE_DONTNEED=1` (HOLED walk)**: still red, now legibly so — 1 of
  40 in the gate plus 2 of 100 direct children, and all of it **checksum
  corruption** (`40 corrupt, 0 entirely zero`), no segfaults. The crash
  portion of the old 4-of-28 belonged to the index-hide; what remains is the
  arm's own documented unsoundness, opt-in and warned at boot.
