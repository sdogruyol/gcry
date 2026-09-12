# "SIGSEGV at 0x0" was a poison word, and the writer was the collector

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `0f95cdd` +
this change

## The report named what was written and never who wrote it

Every fault on `make thread-churn-uaf`'s poisoned arm — 14 of 18, for weeks —
printed the same first line:

```
gcry: SIGSEGV at 0x0 — gcry's freed-block poison (GCRY_POISON_FREED) is in the
faulting context. Something followed a pointer read out of a block that had
already been freed: a use-after-free, not a wild pointer
```

and then nothing about the *writer*, because the only backtrace available was
Crystal's. `Exception::CallStack` allocates its DWARF tables — hundreds of
kilobytes on a fat binary — and needs `Fiber.current`, neither of which exists
in a signal handler on a heap that is already broken. Measured, it produced
`Failed to raise an exception: END_OF_STACK` and
`Thread#current_fiber cannot be nil`, and its allocation **changed the crash**:
the DWARF buffer became the released block, which cost two rounds of
misattribution (`../2026-09-12-thread-churn-large-uaf/`).

## The instrument

A signal-safe walk, from the faulting `ucontext`, allocation-free and
lock-free:

* the faulting PC as `exe+offset` against the load bias captured at `GC.init`
  — the only form that survives a PIE;
* `sp`, `fp`, and on x86_64 `cr2`, the hardware faulting address, printed
  beside `si_addr` rather than instead of it;
* the frame-record chain (`[fp]`/`[fp+8]`, the same shape on x86_64 and
  aarch64), bounded by frame count, a monotonic `fp` and a window above `sp`;
* and, because Crystal builds without `--release` keep locals `%rsp`-relative
  and omit the frame pointer, a conservative fallback: the words above `sp`
  that land in this binary's text. Noise is the right trade — a chain with
  three extra entries names the writer, an empty report does not.

The report ends with the `addr2line` command already assembled.

## First run, first answer

```
gcry: writer — the faulting instruction is at 0x5646a04a54f6 = exe+0x1aa4f6.
      sp 0x7ffe83432d60 fp 0x7ffe83433f68 cr2 0x0
gcry: writer — return addresses above sp: addr2line -f -C -e <binary>
      0x1aa1a9 0x106d50 0x18a7d6 0x13df60 ...
```

```
mark_ref_slot        src/gcry/collect_scan.cr:44
scan_thread_roots    src/gcry/collect_scan.cr:139
                     src/gcry/gc_override.cr:1310
run_collection_body  src/gcry/collect.cr:2182
```

**The writer is the collector.** Not a mutator reading a freed block — gcry
itself, inside its own execution-context root pin.

## And "at 0x0" was never an address

`cr2` said 0 as well, so the instruction really did touch 0 — except the
register did not hold 0. Read out of the same ucontext:

```
rax 0xdead7fb15cbe0848   [rsp+0x10] 0xdead7fb15cbe0848
```

That is a **tagged poison word**: `0xDEAD` in the top 16 bits and the freed
block's address, `0x7fb15cbe0848`, in the low 48. Dereferencing it is a
non-canonical access, and Linux reports a non-canonical fault at address
**0**. So:

* every "SIGSEGV at 0x0" on this arm was a poison dereference, not a null one;
* the poison-in-register line was right about the poison and wrong about the
  reader — it said "something followed a pointer read out of a freed block",
  and the something was the collector;
* and the report could not say which of the nine pin sites did it, because
  each is macro expansion attributed to its `{% if %}`.

## The fix on gcry's side, and what it is not

`mark_ref_slot` computes its argument as `pointerof(obj.@ivar)`, so it is only
as good as `obj` — and `obj` comes out of Crystal's EC structures. It now
refuses a slot address that is zero, non-canonical, or carries the poison tag,
counts it (`ec_root_poisoned_slots`, `ec_root_null_slots`) and names the site
and the freed block the first time:

```
gcry: an execution-context pin site cannot see its object —
collect_scan.cr:174 computed slot address 0xdead7f3ed48e0848, which is this
heap's freed-block poison: the object it belongs to was read out of memory the
collector had already reclaimed. Skipped rather than dereferenced. The freed
block is 0x7f3ed48e0848
```

Line 174 is the `Fiber::ExecutionContext.unsafe_each` pin block. A collector
must not dereference an address it did not validate, and refusing loses no
root: there is no object at a poisoned address to mark.

**It is not a fix for what put poison there.** A live EC-family object is
being freed, and that is still open — the counter is how often it happens, and
the freed block address is where a `GCRY_POISON_HOLDERS` search should be
pointed next.

## What the poison names: a 16-byte block nothing points at

The tagged poison carries the freed block's address, so the pin site can
describe it — and, since `GCRY_POISON_HOLDERS=1` is the arm that produces
these, run the same holders search on it that the release path now runs:

```
gcry: an execution-context pin site cannot see its object — collect_scan.cr:209
      computed slot address 0xdead7f9f91480848 ... the freed block is 0x7f9f91480848
gcry: the freed block is 0x7f9f91480848, in a chunk of size class 0, payload 16 bytes
gcry: holders — explicit roots: 0 of 5 point into it — gcry is not rooting it
gcry: holders — heap: 0 word(s) in 0 live block(s), from 34440 block(s) in 21 chunk(s)
gcry: holders — stack: ... all below the collector's entry SP
```

Two facts follow, and both are new.

**The receiver was loaded out of that block.** `slot_addr` is
`pointerof(obj.@ivar).address`, an address — and it *equals* the poison word.
Only one block's payload carries its own tag, so the word holding `obj` was
inside block `0x7f9f91480848`. The pin loop's receivers come from two places:
`ec` from the intrusive `Thread::LinkedList(ExecutionContext)`, and `sched`
from `ec.@schedulers`. A 16-byte payload is two words — the shape of a
small `Array`'s buffer, which is raw `type_id 0` memory.

**Nothing points at it, anywhere.** Zero explicit roots, zero live blocks,
and every stack hit inside the collection's own frames. So at the moment the
collector reads through it, the block is unreferenced by anything gcry can
see — which is why it was freed, and why no coverage knob has ever moved this
defect.

**And it is 16 bytes**, which is the size of the victim the thread-death
investigation could not name either
(`../2026-09-12-thread-life-root/`: *"it is 16 bytes and it is not the
`Thread`"*). Two investigations that started from different faults are
looking at the same block.

## Where the fault goes after that

Straight to the other reader of the same structure:

```
gcry: writer — the faulting instruction is at ... = exe+0x32db1a
transfer_schedulers_blocked_on_syscall
  /usr/lib/crystal/fiber/execution_context/monitor.cr:78
```

Crystal's **Monitor** thread, walking `ExecutionContext.each` →
`each_scheduler`, dereferencing the same poison with the same `cr2 0x0`
signature. So the freed object is reachable from the EC/scheduler graph and
both the collector and the Monitor read it. The harness rate is unchanged by
the guard (poisoned 14 of 18), which is the honest reading: the guard stops
gcry from faulting on the damage, and the damage is upstream.

The Monitor is the one thread the stop never suspends
(`stw_signal_exempt?`), its registers are only covered when it parks in
`MonitorGate.enter` — measured 238 of 240 collections, so twice it is
elsewhere — and its stack is scanned through `snapshotted_stack_bounds` with
no recorded SP. That is the next thing to read.

## Which load: `sched.@name`

`__LINE__` could not answer that — nine pin sites are macro expansion
attributed to one `{% if %}`, so all of them reported `collect_scan.cr:209`.
A compile-time site tag can, and it is free: the ivar name is in hand at
expansion and a `String` literal is static data.

```
gcry: an execution-context pin site cannot see its object — `sched.@name`
      computed slot address 0xdead7f5690760848 ... the freed block is 0x7f5690760848
gcry: the freed block is 0x7f5690760848, in a chunk of size class 0, payload 16 bytes
```

`sched` comes from `ec.@schedulers.each`. `pointerof(sched.@name).address` is
the poison word, so `sched` itself was read as poison — and since only one
block's payload carries its own tag, the word holding `sched` was inside the
freed block. That block is where the elements live:

> **the freed 16-byte block is the `@schedulers` array's buffer** — two
> pointer slots, freed while the `ExecutionContext` and the `Array` that owns
> it are both live and both pinned by the walk that is reading them.

That is the first time this defect has named a data structure. It also
explains the shape of everything above it: the buffer is `type_id 0` raw
memory with no owner gcry can see once it is unlinked, the collector reads
elements out of it during its own root pin, and Crystal's Monitor reads the
same elements through `each_scheduler` — which is exactly where the fault
lands once gcry stops dereferencing it.

## The owning array, measured at the refusal

Recording the `@schedulers` array before its elements are walked lets the
refusal describe the edge that should have kept the buffer alive. Every number
here is from one report:

```
the freed block is 0x7fd097960840 (the poisoned word was read at 0x7fd097960848),
  in a chunk of size class 0, payload 16 bytes
the owning array is 0x7fd098462620, allocated=true marked=true,
  buffer 0x7fd097960840, allocated base 0x7fd097960840, size 1 capacity 1
the edge that should hold it — @buffer at offset 16 of a 24-byte object,
  in a block of payload 32 — the scan reaches it, atomic=false,
  heap holders of the buffer: 0, of the array itself: 1
```

Two corrections to earlier readings are in there. `live?` answers *occupancy*,
not reachability — it asks `block_allocated?` — so the report now prints
`allocated` and the mark bit separately. And the poisoned address is resolved
to its block before anything is asked about it: it arrives as the poison word
*plus the ivar offset the pin site added*, 8 bytes for `sched.@name`, so the
first version searched `[base+8, base+24)` and answered "nothing points at it"
about a range the buffer's owner does not point into.

## The contradiction that is left, stated as one

With the range corrected, the same report says all of this at once:

* the array is **allocated and marked**, and **not atomic** — so its payload
  is scanned and its edges are followed;
* its block's payload is **32 bytes** and `@buffer` sits at **offset 16**, so
  the scan reaches the word;
* `@buffer` **is** the freed block's base;
* the heap walk finds **1** holder of the array itself, so it is reaching
  these chunks;
* and **0** holders of the buffer.

The last two cannot both be true. The walk visits the block that points at the
array, and the array's own block is in the same walk, and the word at offset 16
of it is the buffer's address.

**It is not the search.** `make holders-find` is the control that walk never
had: three block shapes, one constructed holder each, all found, and a masked
block whose address exists nowhere a walk can see reporting zero. It also
caught a trap worth keeping — a holder whose only ivar is a `UInt64` has no
inner pointers, so Crystal allocates it *atomic*, gcry never scans it, and the
target is reclaimed: the first control drew the first case's own address.

## Resolved: the chunk index and the chunk list disagree

The four payload words settled it. The array's block holds

```
0x100000014  0x1  0x7ff2b2d00840  0x0
```

— `type_id` and size packed in word 0, capacity and shift-offset in word 1,
and **word 2 is the buffer**, the same address the heap walk says nothing
points at. So both reads are of the same memory, and the walk is not reading
that block. One more question, asked at the refusal:

```
the array's chunk is in the index: true, in the @chunks list: FALSE;
the buffer's chunk in the list: true
```

**`@chunk_index` and `@chunks` are not the same set.** They are maintained
separately — `map_chunk` inserts into the index, `unlink_chunk` and the
sweep's drop path remove — and `chunk_containing` reads the index while every
*walk* reads the list. Measured with a dedicated audit
(`GCRY_CHUNK_LIST_AUDIT=1`).

The first version of that audit over-reported and its number has been
corrected here: a chunk the sweep dropped is off `@chunks` and still in the
index until the post-STW flush unmaps it, which is by design, and counting
those gave 2–27 chunks depending on when the collection landed. With the
pending-unmap chain excluded the residual is **1 chunk indexed but not listed,
in about 6 of 14 runs** of `thread_churn_uaf --child`, **0 the other way**, and
none at all on a quiescent program. One chunk is enough: it is one chunk's
worth of objects that read permanently marked.

From there the chain to the fault is mechanical, and every link is either
measured here or read from the source:

1. The array's chunk is in the index and not the list.
2. `clear_all_marks` zeroes bitmap marks through `each_chunk` — the list — so
   that chunk's marks are **never cleared**.
3. Every block in it therefore reads **permanently marked**.
4. `mark_impl_unlocked` has `return if block_marked_in?(chunk, header)`, so the
   array is never pushed onto the mark stack.
5. `scan_object` never runs on it, so its `@buffer` edge is **never followed**.
6. The buffer's chunk *is* in the list, so the sweep reaches it, finds the
   block unmarked, reclaims it and writes poison into it.
7. The next collection's pin walk reads the poisoned element as `sched`;
   `pointerof(sched.@name)` is `poison + 8`, non-canonical, and the kernel
   reports the fault at address 0.

The sweep never reclaiming those chunks is the same divergence seen from the
other side: a chunk off the list is also a chunk that is never swept, which is
a leak rather than a use-after-free and is why nothing noticed.

## What the fix has to be, and what it is not

Not the mark skip, and not the pin site. The invariant is that the index and
the list describe the same set of chunks, and the fix is either to keep them
in sync or to make the walks that carry correctness — mark clearing and the
sweep — read the authority that `chunk_containing` reads.

Two producers are already ruled out by reading them: `map_chunk` links the
list **before** inserting into the index, under one lock, so it cannot leave a
chunk indexed and unlisted; and `unlink_chunk` removes from both under that
same lock, with a comment describing this exact hazard from the other side.

**Attempted and reverted, with numbers.** The remaining suspect was the
sweep's rebuild — `@chunks = kept` replaces the head with a list built by a
walk that started earlier, so a `map_chunk` prepend during the walk is lost.
Splicing the prefix between the current head and the head the walk began at
back in front of `kept` moved nothing: **5 of 14 runs diverging before, 6 of 14
after**. Worth recording for two reasons. The first attempt at it made things
*worse* — 2 chunks to 27 — because when the walk drops `head_at_start` itself
the prefix scan runs to the end of the old list and splices chunks the sweep
had just unmapped back onto it; the splice has to require that the prefix ends
exactly at the recorded head. And the reason it cannot help here is visible in
the condition guarding it: this harness is multi-mutator most of the time, so
`relink_chunks_after_world?` is false and that rebuild does not run at all.

So the producer is still open, and it is not in the three places that looked
like it. The audit is what will tell a fix from a coincidence.
