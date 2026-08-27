# The pattern audit: every structure the stopped world reads unlocked, against every writer a signal can freeze

2026-08-27, Linux x86_64. The chunk-index fix earlier today
(`../2026-08-27-thread-list-tripwire/`) was one instance of a class: an
unlocked in-STW read of a structure whose mutator-side writer is a multi-step
protocol, frozen mid-step by `stop_world`'s signal. This session audited the
class exhaustively and fixed what it found. The memory model used throughout:
signal suspension freezes a thread at a precise instruction, so the collector
sees an exact program-order prefix of the frozen thread's **compiled** stores —
hardware reordering is irrelevant to in-STW readers, compiler reordering of
plain stores is not.

## The inventory

Every lock, every in-STW acquisition, every unlocked in-STW read, every writer
protocol store-by-store. Verdicts:

| structure / lock | verdict |
|---|---|
| chunk index + count | SAFE (today's fix: duplicate-top, release-store count, shift) |
| `index_remove_locked` shift | SAFE (every prefix sorted-with-duplicate) |
| heap bounds min/max | SAFE (per-store monotone-conservative, order-free) |
| `map_chunk` ordering (list+index before bounds) | SAFE, contingent on "no user pointer before `map_chunk` returns" — holds at both call sites |
| TLAB / alloc-batch / freelist pops | SAFE (the flush → mark-FREE-claim → post-mark-scrub protocol; the codebase's own template) |
| `push_size_class_free` half-states | benign either order; depends on "USED ⇒ `next_free` null", which `set_used` guarantees |
| static-range exclusion walk | SAFE (inherits the index fix; duplicates handled) |
| `@chunks` prepend | **SAFE-BY-ORDERING-ONLY** → hardened (below) |
| fresh small chunk mid-`refill_size_class` | **HAZARD** → fixed (below) |
| in-STW `cache_large_chunk` | **HAZARD** → fixed (below) |
| in-STW `index_remove` | **DEADLOCK-RISK** → fixed (below) |

## The four changes

1. **In-STW `index_remove` deferred to the flush.** The sweep's empty-chunk
   drop branch acquired `@index_lock` inside the pause — a lock any suspended
   mutator holds across `chunk_containing` / `index_insert` / the bounds
   updates. The collector spinning on a frozen peer's lock is the 0.21.1
   `@chunk_list_lock` hang, one lock over; it was the **only** unconditional
   in-STW acquisition of a mutator-shared lock left in the tree. The munmap
   this remove serves was already deferred to
   `flush_pending_empty_chunks_locked`; the remove now happens there too,
   immediately before its memory goes, which also keeps
   `refuse_live_release` from reading the chunk's own entry as "still indexed
   inside the range". Reachability was config-gated (in-STW sweep +
   `@parallel_empty_chunk_munmap` + a second mutator) — one predicate change
   away from default, and now not a hazard at any setting.

2. **The small-chunk uninitialised-block guard.** A mutator frozen inside
   `refill_size_class`'s header-init loop leaves a chunk on `@chunks` whose
   unwritten headers are mmap-zeroed: size 0, flags 0 — neither FREE nor
   marked, exactly what the sweep reclaims. The consequences compound: blocks
   that never lived linked onto the class freelist, then clobbered when the
   resumed mutator publishes its own chain (`@freelists[index] = free_head` is
   a wholesale replace) — the same memory reaching two owners; and with
   empty-chunk release on, the all-dead reading classifies the chunk fully
   dead into the warm/DORMANT/munmap paths *under a mutator still writing it*.
   The large path has had precisely this tripwire since 2026-08-24
   (`sweep_large_one`'s size==0 check); the small path now has its analogue:
   size 0 + flags 0 ⇒ count (`sweep_small_uninitialised` on `/gc-stats`),
   treat as live, never reclaim. All-zero is not otherwise reachable —
   `set_used` stores a real payload size, `refill` stores size+FREE.

3. **In-STW large-cache insertion deferred.** `sweep_large_one` appended dead
   large chunks to `@large_freelists` inside the pause with no `@alloc_lock`,
   while a suspended mutator can be frozen mid-`cache_large_chunk` /
   mid-`take_large_free` under that very lock: a tail-append against a
   half-done protocol orphans bucket entries (permanent leak — re-insertion is
   only ever counted, never performed) and drifts `@large_free_bytes`. The
   in-STW sweep now queues them (linked through their own headers, the
   `@pending_large_release` pattern) and `flush_pending_large_cache` inserts
   them under the lock after `start_world`, before the release/trim passes.

4. **`@chunks` head publish is a release store.** The prepend's safety rested
   purely on the source order of two plain stores (header-with-next init, then
   head publish) with nothing stopping the compiler from sinking the first
   past the second — the exact shape the index fix hardened elsewhere. Now
   `Atomic::Ops.store(..., :release)`, same discipline, two lines.

## Measured

Same protocols as this morning, fixed tree:

- `GCRY_PAGE_DONTNEED=1` (the config that reaches the in-STW sweep with 4
  mutators): **0 of 50** direct children and **0 of 40** in the gate — this
  morning the same arm read 2 of 100 + 1 of 40, every failure *checksum
  corruption with no zeroed bytes*, which is the double-hand-out signature of
  hazard 2, not the arm's own DONTNEED-zeroing. 0/90 against 3/140 is
  p ≈ 0.28 — supportive, not conclusive on its own; the mechanism match is
  the stronger half of the argument, and the arm keeps its "known unsound"
  label for the zeroing race the guard does not touch.
- `make page-release-corruption`: **green end to end for the first time in
  this gate's history** — HOLED 0/40 (engaged, 91 MB released), mostly-empty
  0/40 (engaged, 640 MB), control 0/40.
- Mostly-empty `dormant_flush_race` arm: 0 crashes of 50; one child hit the
  deadline with no output — the residual hang family (2 of 100 this morning,
  1 of 50 now), which predates these changes and is the next hunt
  (`GCRY_STW_WATCHDOG_MS` is the tool).
- `make spec` 169, `make spec-process` 27, formatter and knob gate clean.

## What the audit asserts going forward

Three invariants are now load-bearing and named: **no user pointer into a
chunk exists before `map_chunk` returns**; **USED blocks carry
`next_free == null`**; **in-STW code takes no lock a mutator can hold** — the
last one held everywhere except one site, and that site is gone.


---

## The residual hang, hunted and not caught

The one failure mode left in the mostly-empty arm is a child that produces no
output and dies on the 120 s deadline: 2 of 100 this morning, 1 of 50 after
the fixes above, then **1 of 200 with `GCRY_STW_WATCHDOG_MS=5000` armed — and
the watchdog printed nothing**, so whatever wedges is not a world that stayed
stopped: it hangs outside the pause, or before ever reaching one. That rules
out the whole family the watchdog was built for.

A live catcher was built (`hang_catch.sh` beside this file): children run
with no deadline, anything alive past 90 s gets `gdb -p` with
`thread apply all bt` before it is killed. **580 children over an hour, zero
hangs** — today's combined rate is 1 of 780 on the fixed tree, and it did not
reproduce while being watched. Load-sensitivity is suspected (the 2-of-100
morning batch shared the machine with heavier jobs) but not established.

Left open, with the tool in the tree: the next silent deadline kill should be
run through `hang_catch.sh` rather than re-derived. What is already known: it
is not a stuck STW (watchdog silent), it is rare (~0.1–2% depending on load),
and it predates every fix made today — the 0.21.1 sweep-hang family was
in-STW and is closed; this one is something else.

One more sighting for that file: the gate's first dispatch run back in CI had
the **control** arm (`GCRY_TRIM_IMMEDIATE=1`, the deliberately-unsound old
behaviour) hang 3 of 6 children on a two-core runner while the queued arm read
0 of 6 and the control still faulted for real. The gate now scores a hung
control child as neither fault nor pass — the control stands on its faulting
children, and only a queued-arm hang is fatal. Whether the control-arm hang is
this same silent family under a different knob is unknown; it is at least a
far cheaper reproducer candidate (3 of 6 on two cores) for the next
`hang_catch.sh` session.
