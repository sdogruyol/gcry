# acikturkiye under load: a live String is freed mid-serialisation

## What was asked

Production reported `Invalid memory access (signal 11) at address 0x0` in
`String#empty?` <- `unescape_url_param` <- `parse_url` <- a Kemal controller.
Earlier attempts to reproduce that shape in a microbench failed: the closest
harness (`bench/url_params_hash.cr`) crashed 1 of 8 once and then 0 of 112
across every arm, so that reading was withdrawn. This ran the real application
instead.

## Harness

`bin/acik_dbg` — acikturkiye built from its own tree with `-Dgc_none --release
--debug`; its `shard.yml` points at `path: ../gcry`, so it carries the tip.
`wrk -t4 -c64 -d260s` over routes that return 200 **and** take URL parameters
(`/api/v1/submissions/city/:id?page=&q=`, `/api/v1/submissions/:id?...`).

Engagement matters here and was got wrong first: an earlier run drove 293,307
requests that were **all 404**, so `params.url` never ran and the server
survived. Every run below is on routes verified to answer 200.

## Result: 6 of 6 runs died

| Run | Knobs | Outcome |
|-----|-------|---------|
| 1 | default | DIED — `0x7f0f5b800000`, in the heap span, no live chunk |
| 2 | `RELEASE_LEDGER` | DIED — **released, 69632 bytes, large-object release**, at collection 58, faulted 3 collections later |
| 3 | `INTERIOR=1` | DIED — same signature, **69632 bytes**, collection 10, +4 |
| 4 | `DISABLE_LAYOUT=1` | DIED — same signature, **69632 bytes**, collection 177, +49 |
| 5 | debug build | DIED — page-aligned, no ledger match |
| 6 | `SOUND=1` | DIED — page-aligned, no ledger match |

Four of the ledger hits are the **same mapped size, 69632 bytes** = 65536 + one
page of headers, i.e. a **64 KiB allocation** every time.

## Where it dies

Run 5 was built with `--debug` and run under `setarch -R`, so the frames
resolve against the recorded load base `0x555555554000`:

    json/builder.cr:154   JSON::Builder#write   <- fault
    io.cr:488             IO#write_string
    string.cr:5595        String#to_s(IO)
    json/builder.cr:115   JSON::Builder#string
    ...
    json/serialization.cr:299  JSON::Serializable#to_json
    json/to_json.cr:165        Array#to_json
    src/controllers/api/v1/cities_controller.cr:55

`builder.cr:154` is `case byte = cursor.value` — a **read of the source
String's bytes**, walking forward. Both symbolised faults are **exactly page
aligned**, which is what walking off the end of a live mapping looks like: the
String's `@bytesize` header was already garbage, so `to_slice` handed the loop
a length that ran past the object.

So the String was freed and its block reused before it was serialised. That is
the same defect the production trace shows from the other side: a freed and
reused `Hash` buffer yields a null value, and `String#empty?` faults at 0x0.

## What this rules out

`GCRY_SOUND=1` — interior pointers, unaligned candidates, static roots,
type_id gate off, `stw_multi_*_lag = 0`, scrub off, blacklist off — **does not
fix it**. Neither does `GCRY_INTERIOR=1` or `GCRY_DISABLE_LAYOUT=1` alone. The
defect is therefore not one of the documented root-completeness axes in
`docs/SOUND-DEFAULTS.md`.

`Heap#realloc` does not free its argument and `GC.free` reaches Crystal only
through the zlib and GMP allocator hooks, so the 64 KiB blocks were freed by
**sweep** — they were unmarked at a collection while still live.

## Boehm control: survives the same load

Same source, same routes, same `wrk -t4 -c64 -d260s`, built without
`-Dgc_none`:

| Collector | Outcome | Throughput |
|-----------|---------|-----------:|
| gcry | **6 of 6 died** | 20–326 req/s |
| Boehm | **survived** | 626 req/s |

Boehm did strictly more work — roughly 2× to 30× the requests of any gcry run —
so it drove the same code paths harder and still finished. The defect is the
collector's, not the application's.

## The mark audit names it

`GCRY_MARK_AUDIT=1` walks every marked block before the sweep and reports any
base pointer into a block the sweep is about to free:

| Arm | requests | collections with missed edges | outcome |
|-----|---------:|------------------------------:|---------|
| `layout_precise` on (tip) | 25,835 | **193 of 216** | DIED |
| `GCRY_DISABLE_LAYOUT=1` | 74,035 | **0** | alive |

Every reported edge had the same shape: a **marked parent whose first Int32
reads 208**, 64 bytes, pointing at +24 and +56 to unmarked 32-byte blocks,
most of them ATOMIC — short `String`s.

`GCRY_LAYOUT_DUMP=1` (added here) prints what was registered for that id:

    gcry: layout tid 208 hash alloc 64 cap 56 scan[] noscan[16 8]

A `Hash`. And Crystal's `Hash` has no pointer at +24 or +56 at all:

    +4  first          +8  entries      +16 indices
    +24 size           +28 deleted_count
    +32 indices_bytesize  +33 indices_size_pow2  +34 compare_by_identity
    +40 block                     instance_sizeof = 56

+24 is two `Int32`s and +56 is past the end of the type. So those blocks were
never `Hash`es. They were scanned to `Hash`'s map because of the key.

## Root cause: the layout key is a conservatively read word

`scan_object` picks a layout with `tid = user.as(Int32*).value` — the payload's
**first Int32**. For a real object that is the type id. For a raw buffer it is
whatever the first element happens to hold, and **Crystal stores a union's type
id in its first four bytes**, so a buffer of union values (`Array(JSON::Any)`,
`Hash::Entry` with a union value — this application is full of both) begins
with exactly the kind of small integer that collides with a registered class.
The `alloc_size` gate does not help: both are 64-byte blocks.

The same collision had already been found once from the other side — the
`scan_cap` branch carries a comment about "raw buffers whose first Int32
randomly equals a registered type_id", fixed there by requiring `size_match`.
The precise-fields branch has the identical key and no such guard.

Under the collision the block lost everything the wrong map did not mention:
its real pointers at +24 and +56 were never marked, and `scan_hash_object`'s
sanity checks (`entries.null?`, `pow2 >= 63`, …) each `return`ed, so the body
was not scanned conservatively either.

## Fix

Two parts, in `scan_object` / `scan_hash_object`:

1. **`scan_hash_body`** — word-scan the object's own body alongside the entry
   walk, demoting only `@entries` / `@indices` to `mark_noscan`. Seven words for
   a 56-byte `Hash`; it also covers what the map never modelled (`@block`'s
   closure pointer, and size-class slack).
2. **`hash_shape_plausible?`** — validate the shape before trusting the map at
   all: sane `@indices_size_pow2`, non-negative `@size` / `@deleted_count` that
   fit the implied capacity, `@entries` / `@indices` null or in the heap. A
   block that fails degrades to exactly the conservative scan it would have got
   unregistered — including no `mark_noscan` demotion, which is itself a claim
   about the type.

Measured, same harness, audit on:

| Arm | requests | collections with missed edges | outcome |
|-----|---------:|------------------------------:|---------|
| before | 25,835 | 193 of 216 | DIED |
| `GCRY_DISABLE_LAYOUT=1` | 74,035 | 0 | alive |
| **after** | **75,022** | **0** | **alive** |

## Not the whole story

At full speed with the audit off, the fix took the crash from 6 of 6 to 1 of 2:
one 260 s run finished at 432 req/s, the next died — with the *other*
signature, the 69632-byte large-object release this log opened with. So there
is a second defect here, and it is the one that also killed the
`GCRY_DISABLE_LAYOUT=1` run at 240 s. The mark audit reports zero missed **heap**
edges after the fix, which points the remainder at a **root**, not an edge: a
64 KiB buffer held only from a stack, a register, or a parked fiber.


---

# The second defect, and what it is not

The layout fix takes the mark audit to zero missed edges and takes most
runs to the end, but the crash this log opened with is still there: a
**69632-byte large chunk**, released down the large-object path, written
into afterwards. Four paired 260 s runs after the fix, `default` and
`GCRY_SOUND=1` alternating, died **4 of 4** with that signature.

## What the victim is

The write offsets across five reports — 3112, 5672, 6376, 7784, 17384 —
are all congruent modulo 32 once the chunk and block headers are taken
off. Stride 32 is `Hash::Entry(String, JSON::Any)`, which is the entry
table of the type this application registers. 69632 is 65536 plus one
page: a 64 KiB allocation.

## Ruled out, each by measurement

| Hypothesis | Arm | Result |
|---|---|---|
| a missed ambient root | `GCRY_SOUND=1` (interior, unaligned, lag 0, gate off) | died 2 of 2 |
| interior pointers alone | `GCRY_INTERIOR=1` | died |
| precise bodies | `GCRY_DISABLE_LAYOUT=1` | died at 240 s |
| the lazy post-STW sweep | `GCRY_DISABLE_LAZY_SWEEP=1` | died |
| a chunk published before its block header | `sweep_large_uninitialised` counter | **0** over 334 collections |
| parked fiber stacks not scanned at all | `first_mark_parked_objects` | 6701 objects / 4.6 MB per run — they are scanned |
| the plain layout branch losing edges the way the hash one did | word-scan the plain body | died 2 of 2, and the mark audit had already reported 0 missed edges with the branch unchanged. Reverted: an argued fix that fixes nothing. |

`Heap#realloc` does not free its argument and Crystal reaches `GC.free`
only through the zlib and GMP hooks, so the block was freed by the sweep:
it was unmarked at a major collection.

## Rate

Six runs at the tip, 220 s each, `GCRY_SEGV_REPORT=1 GCRY_RELEASE_LEDGER=1`:
**3 of 6 died**, all with the 69632-byte signature. Before the layout fix the
same harness family was 6 of 6. The survivors ran at 412–438 req/s and the
deaths at 92–349, so the crash correlates with the slower runs rather than the
busier ones.

## It hides from its own instrument

With **both** audits on — `GCRY_MARK_AUDIT=1 GCRY_ADDRESS_SPACE_AUDIT=1` — the
run finished 87,750 requests with **0 missed edges, no marked holder, and no
crash**. Both audits run inside the pause and lengthen it considerably. So the
remaining defect is timing-sensitive in a way the marking questions are not,
and the instrument that would name it is also the thing that suppresses it.
`GCRY_UNMAP_GUARD=1` behaves the same way: one 260 s run at 461 req/s, no
crash.

That, plus the elimination table above, points away from liveness entirely.
Nothing marked referenced the block when it died, no root did, and no thread
is missing from the stopped set — yet a mutator writes into it afterwards.

## Also eliminated

| Hypothesis | Arm | Result |
|---|---|---|
| a thread gcry never sees, so never stops or scans | `GCRY_THREAD_CENSUS=1` | **291 checks, 0 gaps** — the stopped set accounts for every OS thread |
| the same block cached twice, or taken off a freelist while USED | `large_cached_twice` / `large_taken_used` | **0** and **0** over 672 collections |

## The one live thread

With the audit aimed at 64 KiB blocks, one dying block's address was found
in a **marked, used, 32-byte, scanned** heap block whose first Int32 reads
128 — an `Array`-shaped object, and 128 is not a registered type_id in
this program, so it is scanned conservatively and the edge should have
been followed. The mark audit was not enabled in that run, so this is one
observation and not yet a contradiction. Running both audits together is
the next step.

`GCRY_UNMAP_GUARD=1` survived a 260 s run at 461 req/s where the ledger
arm died — one run, and not yet a claim.


---

# Where the second defect actually lives: the address space, not the object graph

Every liveness question has now come back negative, and one non-liveness
question has come back positive.

## The positive result

`GCRY_UNMAP_GUARD=1` — whose only effect is that a released range is
`mprotect(PROT_NONE)`ed and **kept** instead of being handed back to the
kernel:

| Arm | Runs | Died | Throughput |
|-----|-----:|-----:|-----------:|
| tip | 6 | **3** | 92–438 req/s |
| `GCRY_UNMAP_GUARD=1` | **11** | **0** | 432–537 req/s |

Fisher exact on 0/11 against 3/6 is p ≈ 0.02. The guard arm is also
consistently the *faster* one, which is what a run that is not thrashing
toward a crash looks like.

Engagement is verified rather than assumed: `guard_slots_used` reached 675 of
8192 with **0 overflows** by collection 299, so every release in that run was
guarded and the arm never degenerated into the baseline.

## What that rules in, and what it rules out

Under the guard a stale pointer into a released range would still fault —
`PROT_NONE` faults on read. **Nothing faulted, in 11 runs.** So the defect is
not a dangling pointer being dereferenced. What the guard removes is the other
thing: the address is never handed back, so no later `mmap` can be given it.
And reuse is not rare — `release_remapped` counted 15 released bases handed
back by collection 22.

That is consistent with everything else here. Nothing marked referenced the
block when it died; no root did; no thread was missing from the stopped set;
the chunk index was consistent at every one of 172 collections; no base was
released twice; zeroing every allocation changed nothing. The object graph is
not where this lives.

## Eliminated, with engagement shown

| Hypothesis | Arm | Engagement | Result |
|---|---|---|---|
| a base released twice with no remap between | `note_release_base` | `release_remapped` = 15 | `release_double` = **0** |
| a fresh block that is not really zero | `GCRY_ALWAYS_CLEAR=1` | — | **4 of 4** died |
| a stale or overlapping chunk-index entry | `GCRY_INDEX_AUDIT=1` | 172 audits in 172 collections | overlaps **0**, mismatch **0**; 3 of 3 still died, so the audit does not hide it |

## Mitigation available today

`GCRY_UNMAP_GUARD=1` is a measured, significant mitigation and costs address
space rather than RSS (the pages are dropped by `PROT_NONE` exactly as `munmap`
drops them). It is bounded: after 8192 guarded ranges it overflows and releases
normally again, so it is protection with a ceiling, not a fix.


## How long does the danger last?

`GCRY_RELEASE_QUARANTINE=N` holds a released range `PROT_NONE` for N
collections and only then returns the address. The pages go back to the OS
exactly as `munmap` sends them, so the cost is address space, not RSS.

| Arm | Runs | Died | Engagement |
|-----|-----:|-----:|------------|
| tip | 6 | 3 | — |
| `GCRY_RELEASE_QUARANTINE=1` | 4 | **2** | 140–172 quarantined releases per run, 0 forced drains |
| `GCRY_UNMAP_GUARD=1` (hold forever) | 11 | **0** | 675 of 8192 slots, 0 overflows |

One collection is not enough. The first attempt at this arm measured
`quarantined_releases = 0` and would have read as "no effect" — the release
loop inside `trim_large_cache` was not wired to the quarantine, so the arm was
the baseline. Caught by asking the counter rather than trusting the knob.

## A second, local reproducer

The re-measurement of `make large-cache-race` with the `guard_user_tag`
ordering restored finished:

| Arm | segv |
|-----|-----:|
| `GCRY_UNMAP_GUARD=1` | **2 of 40** |
| default | **0 of 40** |

Under the guard a released range stays mapped `PROT_NONE`, so a stale access
faults instead of quietly landing in whatever the kernel put there next. Those
two crashes are therefore real use-after-frees that the default arm **hides** —
a local, reproducible defect at ~5%, with every instrument in this tree
available to it and no HTTP server in the way.


---

# The second defect, found: the bounds walk could shut a live chunk out

## What it is

`update_heap_bounds_after_unmap` recomputes `@heap_min` / `@heap_max` by
walking `@chunks`, then **assigns** them. It runs with the world running, from
`trim_large_cache`, `flush_pending_empty_chunks` and
`flush_pending_large_release`. Small chunks reach `map_chunk` under the
**size-class freelist lock**, not the `@alloc_lock` most of those callers hold,
so a chunk mapped during the walk can have its bounds published by
`note_mapped` and then overwritten by the assignment.

A chunk outside `[@heap_min, @heap_max)` is a chunk `find_block` answers `nil`
for. Every conservative pointer into it is dropped by the mark, and its objects
are swept while live.

## Why every instrument said the heap was fine

The mark audit resolves its candidates with the same `find_block`. When the
bounds exclude a chunk, the audit is blind to exactly the edges that are being
lost — which is why it reported **0 missed edges over 106,402 audited edges**
in runs that crashed, and why the kernel-side address-space walk could find a
*marked* holder for a dying block while gcry's own heap walk called the same
address "not in the heap".

It also explains the shape of every other result here:

- `GCRY_UNMAP_GUARD=1` was 0 of 11 — the bounds are only recomputed after an
  unmap, and the guard never unmaps.
- `GCRY_RELEASE_QUARANTINE=32` moved the fault later by exactly the quarantine
  length (`Collections since` 34, 36, 57, 85, all > 32) — the recompute happens
  at the real `munmap`, not at the release decision.
- Everything else came back negative because the object graph really was
  intact.

## Measured

A detector that walks `@chunks` again after the assignment and counts chunks
outside the new bounds:

| Arm | Runs | Died | Detector |
|-----|-----:|-----:|----------|
| tip, detector only | 3 | **3** | fired in **3 of 3**, at collections 21, 24, 126 |

The fix is that same walk, widening instead of only counting. Widening is safe
against a chunk mapped after it, too: `map_chunk` links the chunk into
`@chunks` before `note_mapped` publishes its bounds, so either the walk sees it
and widens, or the publication lands after the store and survives.

| Arm | Runs | Died | Throughput |
|-----|-----:|-----:|-----------:|
| tip (comparable arms) | 9 | **6** | 92–438 req/s |
| with the repair | **12** | **0** | 339–586 req/s |

Fisher exact p ≈ 0.0007, and the repair is engaged rather than assumed — the
counter reaches 63 in a single 220 s run.

Throughput moves with it: the fastest runs before the fix were the ones that
happened not to crash, and after it every run is in that band.
